#
# Some unit tests.
#

use strict;
use warnings;

use Checksummer qw//;
use Checksummer::Util qw//;
use File::Path qw//;
use File::Temp qw//;

sub main {
	Checksummer::Util::set_debug(1);

	my $failures = 0;

	if (!test_checksummer()) {
		print "Checksummer tests failed\n";
		$failures++;
	}

	if (!test_database()) {
		print "Database tests failed\n";
		$failures++;
	}

	if (!test_util()) {
		print "Util tests failed\n";
		$failures++;
	}

	if ($failures == 0) {
		print "All tests completed successfully\n";
		return 1;
	}

	print "Some tests failed!\n";
	return 0;
}

# Package Checksummer tests
sub test_checksummer {
	my $failures = 0;

	if (!test_read_config()) {
		$failures++;
	}

	if (!test_run()) {
		$failures++;
	}

	if (!test_is_file_excluded()) {
		$failures++;
	}

	if (!test_checksum_mismatch()) {
		$failures++;
	}

	return $failures == 0;
}

sub test_read_config {
	my @tests = (
		# A config with a path that does not exist.
		{
			config => "
/dir1
",
			want_error => 1,
			paths      => [],
			exclusions => [],
		},

		# A config with paths that do exist and are absolute, and exclusions
		# that are absolute.
		{
			config => "
# Nice dir
/tmp

/home

!/home/horgh
!/home/tester
",
			want_error => 0,
			paths      => ['/tmp', '/home',],
			exclusions => ['/home/horgh', '/home/tester',],
		},

		# A config with paths that are not absolute.
		{
			config => "
# Nice dir
./tmp

/home

!/home/horgh
!/home/tester
",
			want_error => 1,
			paths      => [],
			exclusions => [],
		},

		# A config where paths are absolute, but exclusions are not.
		{
			config => "
# Nice dir
/tmp

/home

!./home/horgh
!./home/tester
",
			want_error => 1,
			paths      => [],
			exclusions => [],
		},

		# A config where one of the paths is a regular file.
		{
			config => "
/etc/passwd

/home

!/home/horgh
!/home/tester
",
			want_error => 1,
			paths      => [],
			exclusions => [],
		},

		# No paths at all.
		{
			config => "
!/home/horgh
!/home/tester
",
			want_error => 1,
			paths      => [],
			exclusions => [],
		},
	);

	my $tmpfile = File::Temp::tmpnam();

	my $failures = 0;

	TEST: foreach my $test (@tests) {
		if (!write_file($tmpfile, $test->{ config })) {
			print "test_read_config: Unable to write file: $tmpfile\n";
			$failures++;
			next;
		}

		my $config = Checksummer::read_config($tmpfile);
		unlink $tmpfile;

		if ($test->{ want_error }) {
			if ($config) {
				print "read_config() succeeded, wanted error.\n";
				print "config = $test->{ config }\n";
				$failures++;
				next;
			}

			next;
		}

		if (!$config) {
			print "read_config() failed, wanted success\n";
			print "config = $test->{ config }\n";
			$failures++;
			next;
		}

		if (scalar @{ $config->{ paths } } != scalar @{ $test->{ paths } }) {
			print "read_config() yielded " . scalar(@{ $config->{ paths } })
				. " paths, wanted " . scalar(@{ $test->{ paths } }) . "\n";
			print "config = $test->{ config }\n";
			$failures++;
			next;
		}

		for (my $i = 0; $i < scalar @{ $test->{ paths } }; $i++) {
			my $wanted_path = $test->{ paths }[ $i ];
			my $got_path = $config->{ paths }[ $i ];

			if ($wanted_path ne $got_path) {
				print "read_config() path mismatch. path $i is $got_path, wanted $wanted_path\n";
				print "config = $test->{ config }\n";
				$failures++;
				next TEST;
			}
		}

		if (scalar @{ $config->{ exclusions } } != scalar @{ $test->{ exclusions } }) {
			print "read_config() yielded " . scalar(@{ $config->{ exclusions } })
				. " exclusions, wanted " . scalar(@{ $test->{ exclusions } }) . "\n";
			print "config = $test->{ config }\n";
			$failures++;
			next;
		}

		for (my $i = 0; $i < scalar @{ $test->{ exclusions } }; $i++) {
			my $wanted = $test->{ exclusions }[ $i ];
			my $got = $config->{ exclusions }[ $i ];

			if ($wanted ne $got) {
				print "read_config() exclusion mismatch. exclusion $i is $got, wanted $wanted\n";
				print "config = $test->{ config }\n";
				$failures++;
				next TEST;
			}
		}
	}

	if ($failures == 0) {
		return 1;
	}

	print "test_read_config: $failures/" . scalar(@tests) . " failed\n";
	return 0;
}

sub test_run {
	my $hex_md5sum_of_123 = '202cb962ac59075b964b07152d234b70';
	my $binary_md5sum_of_123 = pack('H*', $hex_md5sum_of_123);

	my @tests = (
		# A set of files, all with checksums in the database, all matching.
		{
			desc   => 'all files in db, same checksums',
			config => {
				paths      => ['/dir1', '/dir2'],
				exclusions => [],
			},
			db_records => [
				{
					file          => '/dir1/test.txt',
					checksum      => $binary_md5sum_of_123,
					checksum_time => 5,
					modified_time => 4,
					ok            => 1,
				},
				{
					file          => '/dir2/test.txt',
					checksum      => $binary_md5sum_of_123,
					checksum_time => 5,
					modified_time => 4,
					ok            => 1,
				},
			],
			files => [
				{ path => '/dir1',          dir     => 1 },
				{ path => '/dir1/test.txt', content => '123' },
				{ path => '/dir2',          dir     => 1 },
				{ path => '/dir2/test.txt', content => '123' },
			],
			# Currently a subset of columns.
			db_records_after => [
				{ file => '/dir1/test.txt', checksum => $binary_md5sum_of_123, ok => 1 },
				{ file => '/dir2/test.txt', checksum => $binary_md5sum_of_123, ok => 1 },
			],
			want_error => 0,
		},

		# A set of files, none of which have checksums in the database yet.
		{
			desc   => 'no checksums in db',
			config => {
				paths      => ['/dir1', '/dir2'],
				exclusions => [],
			},
			db_records => [
			],
			files => [
				{ path => '/dir1',          dir     => 1 },
				{ path => '/dir1/test.txt', content => '123' },
				{ path => '/dir2',          dir     => 1 },
				{ path => '/dir2/test.txt', content => '123' },
			],
			# Currently a subset of columns.
			db_records_after => [
				{ file => '/dir1/test.txt', checksum => $binary_md5sum_of_123, ok => 1 },
				{ file => '/dir2/test.txt', checksum => $binary_md5sum_of_123, ok => 1 },
			],
			want_error => 0,
		},

		# A set of files, one of which has a checksum mismatch that is not a
		# problem since the mtime is after the last time we computed the checksum.
		{
			desc   => 'ok checksum mismatch',
			config => {
				paths      => ['/dir1', '/dir2'],
				exclusions => [],
			},
			db_records => [
				{
					file          => '/dir1/test.txt',
					checksum      => $binary_md5sum_of_123,
					checksum_time => 5,
					modified_time => 4,
					ok            => 1,
				},
				{
					file          => '/dir2/test.txt',
					checksum      => 1,
					checksum_time => 5,
					modified_time => 4,
					ok            => 1,
				},
			],
			files => [
				{ path => '/dir1',          dir     => 1 },
				{ path => '/dir1/test.txt', content => '123' },
				{ path => '/dir2',          dir     => 1 },
				{ path => '/dir2/test.txt', content => '123', mtime => 6, },
			],
			# Currently a subset of columns.
			db_records_after => [
				{ file => '/dir1/test.txt', checksum => $binary_md5sum_of_123, ok => 1 },
				{ file => '/dir2/test.txt', checksum => $binary_md5sum_of_123, ok => 1 },
			],
			want_error => 0,
		},

		# A set of files, one of which has a checksum mismatch that is a problem
		# since the mtime is the same as the last time we checked it.
		{
			desc   => 'bad checksum mismatch',
			config => {
				paths      => ['/dir1', '/dir2'],
				exclusions => [],
			},
			db_records => [
				{
					file          => '/dir1/test.txt',
					checksum      => $binary_md5sum_of_123,
					checksum_time => 5,
					modified_time => 4,
					ok            => 1,
				},
				{
					file          => '/dir2/test.txt',
					checksum      => 1,
					checksum_time => 5,
					modified_time => 4,
					ok            => 1,
				},
			],
			files => [
				{ path => '/dir1',          dir     => 1 },
				{ path => '/dir1/test.txt', content => '123' },
				{ path => '/dir2',          dir     => 1 },
				{ path => '/dir2/test.txt', content => '123', mtime => 4 },
			],
			# Currently a subset of columns.
			db_records_after => [
				{ file => '/dir1/test.txt', checksum => $binary_md5sum_of_123, ok => 1 },
				{ file => '/dir2/test.txt', checksum => $binary_md5sum_of_123, ok => 0 },
			],
			want_error => 0,
		},

		# Regular file. Checksum mismatch, and the mtime is prior to the last we
		# know about. This is problematic.
		{
			desc   => 'checksum mismatch, mtime is before, and not ok',
			config => {
				paths      => ['/dir1'],
				exclusions => [],
			},
			db_records => [
				{
					file          => '/dir1/test.txt',
					checksum      => 'ff',
					checksum_time => 10,
					modified_time => 6,
					ok            => 1,
				},
			],
			files => [
				{
					path => '/dir1',
					dir  => 1,
				},
				{
					path    => '/dir1/test.txt',
					mtime   => 5,
					content => "123",
				},
			],
			db_records_after => [
				{
					file     => '/dir1/test.txt',
					checksum => pack('H*', '202cb962ac59075b964b07152d234b70'),
					ok       => 0,
				},
			],
			want_error => 0,
		},

		# Symlink. It should be skipped.
		{
			desc   => 'symlink',
			config => {
				paths      => ['/dir1'],
				exclusions => [],
			},
			db_records => [
			],
			files => [
				{
					path => '/dir1',
					dir  => 1,
				},
				{
					path    => '/dir1/testlink',
					symlink => 1,
				},
			],
			db_records_after => [
			],
			want_error => 0,
		},

		# A file is not in the database, and it's excluded. We should not see a
		# checksum for it.
		{
			desc   => 'file is excluded',
			config => {
				paths      => ['/dir1'],
				exclusions => ['/dir1/test.txt'],
			},
			db_records => [
			],
			files => [
				{
					path => '/dir1',
					dir  => 1,
				},
				{
					path => '/dir1/test.txt',
					dir  => 1,
				},
			],
			db_records_after => [
			],
			want_error => 0,
		},
	);

	my $db_file = File::Temp::tmpnam();
	my $working_dir = File::Temp::tmpnam();

	my $failures = 0;

	TEST: foreach my $test (@tests) {
		print "test_run: Running test $test->{ desc }\n";

		# Populate the database with the initial state we specify.

		my $dbh = Checksummer::Database::open_db($db_file);
		if (!$dbh) {
			print "test_run: Cannot open database\n";
			$failures++;
			next;
		}

		# Prepend all paths to set in the db with the working dir. This is what
		# we'll see when we run checks shortly.
		for (my $i = 0; $i < @{ $test->{ db_records } }; $i++) {
			$test->{ db_records }[ $i ]{ file } =
				$working_dir . $test->{ db_records }[ $i ]{ file };
		}

		if (!_insert_db_records($dbh, $test->{db_records})) {
			print "test_run: Unable to perform database updates.\n";
			$failures++;
			unlink $db_file;
			next;
		}

		if (!$dbh->disconnect) {
			print "test_run: Unable to disconnect from database: " . $dbh->errstr . "\n";
			$failures++;
			unlink $db_file;
			next;
		}

		# Create files to check.
		if (!populate_directory($working_dir, $test->{ files })) {
			print "test_run: Unable to create files to test with\n";
			$failures++;
			unlink $db_file;
			next;
		}

		# Paths/exclusions must have the working dir prepended.

		for (my $i = 0; $i < @{ $test->{ config }{ paths } }; $i++) {
			my $path = $test->{ config }{ paths }[ $i ];
			$test->{ config }{ paths }[ $i ] = $working_dir . $path;
		}

		for (my $i = 0; $i < @{ $test->{ config }{ exclusions } }; $i++) {
			my $path = $test->{ config }{ exclusions }[ $i ];
			$test->{ config }{ exclusions }[ $i ] = $working_dir . $path;
		}

		# Check.
		my $success = Checksummer::run($db_file, 1, $test->{ config },
			1);

		if ($test->{ want_error }) {
			if ($success) {
				print "test_run: wanted failure, but succeeded\n";
				$failures++;
				File::Path::remove_tree($working_dir);
				unlink $db_file;
				next;
			}

			File::Path::remove_tree($working_dir);
			unlink $db_file;
			next;
		}

		if (!$success) {
			print "test_run: wanted success, but failed\n";
			$failures++;
			File::Path::remove_tree($working_dir);
			unlink $db_file;
			next;
		}

		my $dbh2 = Checksummer::Database::open_db($db_file);
		if (!$dbh2) {
			print "test_run: unable to open database\n";
			$failures++;
			File::Path::remove_tree($working_dir);
			unlink $db_file;
			next;
		}

		my $db_records_after = get_all_db_records($dbh2);
		$dbh2->disconnect;
		if (!$db_records_after) {
			print "test_run: error retrieving records\n";
			$failures++;
			File::Path::remove_tree($working_dir);
			unlink $db_file;
			next;
		}

		if (scalar @$db_records_after != @{ $test->{db_records_after} }) {
			print "test_run: test: $test->{desc}: got " . scalar(@$db_records_after) .
				" records, wanted " . scalar(@{ $test->{db_records_after} }) .
				" records\n";
			$failures++;
			File::Path::remove_tree($working_dir);
			unlink $db_file;
			next;
		}

		for (my $i = 0; $i < @{ $test->{db_records_after} }; $i++) {
			my $wanted = $test->{db_records_after}[$i];
			my $got = $db_records_after->[$i];
			foreach my $key (keys %$wanted) {
				my $wanted_value = $wanted->{$key};
				if ($key eq 'file') {
					$wanted_value = $working_dir . $wanted_value;
				}
				if ($got->{$key} ne $wanted_value) {
					print "test_run: test: $test->{desc}: got $key = " . $got->{$key} .
						", wanted " . $wanted_value . "\n";
					$failures++;
					File::Path::remove_tree($working_dir);
					unlink $db_file;
					next TEST;
				}
			}
		}

		File::Path::remove_tree($working_dir);
		unlink $db_file;
	}

	if ($failures == 0) {
		return 1;
	}

	print "test_run: $failures/" . scalar(@tests) . " tests failed\n";
	return 0;
}

# Create and populate a given directory with file(s) specified.
#
# Several parts of checksummer rely on interacting with files on disk. It is
# useful to be able to create a set of files to set with.
#
# You describe the files to create by providing them in an array reference.
# Each element in the array must be a hash reference. The possible keys are:
#
# - path, path to the file. This will be under the working directory (this
#   function takes care of that. This is required.
# - dir, boolean, whether the file should be a directory. Optional. Default 0.
# - symlink, boolean, whether the file should be a symlink. Optional. Default 0.
# - mtime, numeric, unixtime, the modified time to set on a file. Optional.
#   Default 0.
# - content, string, the content to put in the file if it is a regular file.
#   Optional. Defaults to ''.
sub populate_directory {
	my ($working_dir, $files) = @_;
	if (!defined $working_dir || length $working_dir == 0 || !$files) {
		print "populate_directory: Invalid parameter\n";
		return 0;
	}

	if (!mkdir $working_dir) {
		print "populate_directory: Unable to create directory: $working_dir: $!\n";
		return 0;
	}

	foreach my $file (@{ $files }) {
		my $path = $working_dir . $file->{ path };

		if ($file->{ symlink }) {
			if (!symlink('/tmp', $path)) {
				print "populate_directory: Unable to symlink: $path\n";
				File::Path::remove_tree($working_dir);
				return 0;
			}

			next;
		}

		if ($file->{ dir }) {
			if (!mkdir $path ) {
				print "populate_directory: Unable to mkdir $path\n";
				File::Path::remove_tree($working_dir);
				return 0;
			}

			next;
		}

		# Regular file.

		my $content = '';
		if (exists $file->{ content }) {
			$content = $file->{ content };
		}

		if (!write_file($path, $content)) {
			print "populate_directory: Unable to write file: $path\n";
			File::Path::remove_tree($working_dir);
			return 0;
		}

		if (exists $file->{ mtime } &&
			utime($file->{ mtime }, $file->{ mtime }, $path) != 1) {
			print "populate_directory: Unable to set mtime: $path\n";
			File::Path::remove_tree($working_dir);
			return 0;
		}
	}

	return 1;
}

sub test_is_file_excluded {
	my @tests = (
		# Excluded.
		{
			exclusions => ['/tmp', '/bin'],
			path       => '/tmp/test.txt',
			output     => 1,
		},

		# Not excluded.
		{
			exclusions => ['/tmp', '/bin'],
			path       => '/home/horgh/test.txt',
			output     => 0,
		},
	);

	my $failures = 0;

	foreach my $test (@tests) {
		my $r = Checksummer::is_file_excluded($test->{ exclusions },
			$test->{ path });
		if ($r != $test->{ output }) {
			print "is_file_excluded(@{ $test->{ exclusions } }, $test->{ path }) = $r, wanted $test->{ output }\n";
			$failures++;
			next;
		}
	}

	if ($failures == 0) {
		return 1;
	}

	print "$failures/" . (scalar(@tests)) . " test_is_file_excluded tests failed\n";
	return 0;
}

sub test_checksum_mismatch {
	my @tests = (
		{
			description      => 'The change is fine. The current mtime is after the last time we recorded the mtime',
			db_modified_time => 6,
			modified_time    => 7,
			output           => 0,
		},

		{
			description      => 'The change is a problem. The current mtime is prior to the last time we recorded the mtime.',
			db_modified_time => 4,
			modified_time    => 3,
			output           => 1,
		},

		{
			description      => 'The change is a problem. The current mtime is the same as the last time we recorded the mtime.',
			db_modified_time => 4,
			modified_time    => 4,
			output           => 1,
		},
	);

	my $failures = 0;

	foreach my $test (@tests) {
		my $db_record = {
			# Arbitrary. It's used in the report.
			checksum_time => 42,
			modified_time => $test->{ db_modified_time },
		};

		my $r = Checksummer::checksum_mismatch('testfile', $db_record,
			$test->{ modified_time });

		if ($r != $test->{ output }) {
			print "checksum_mismatch() = $r, wanted $test->{ output }\n";
			$failures++;
			next;
		}
	}

	if ($failures == 0) {
		return 1;
	}

	print "$failures/" . (scalar(@tests)) . " test_checksum_mismatch tests failed\n";
	return 0;
}

sub test_database {
	my $failures = 0;

	if (!test_prune_database()) {
		$failures++;
	}

	return $failures == 0;
}

sub test_prune_database {
	print "Starting prune_database() tests...\n";

	my @tests = (
		# Records present, but none to prune.
		{
			records_before => [
				{
					file          => '/dir/test.txt',
					checksum      => '123',
					checksum_time => 15,
					modified_time => 10,
					ok            => 1,
				},
				{
					file          => '/dir/test2.txt',
					checksum      => '123',
					checksum_time => 15,
					modified_time => 10,
					ok            => 1,
				},
			],
			unixtime      => 10,
			pruned        => 0,
			records_after => {
				'/dir/test.txt'  => {
					checksum      => '123',
					checksum_time => 15,
					modified_time => 10,
				},
				'/dir/test2.txt' => {
					checksum      => '123',
					checksum_time => 15,
					modified_time => 10,
				},
			},
		},

		# No records present.
		{
			records_before => [
			],
			unixtime      => 10,
			pruned        => 0,
			records_after => {
			},
		},

		# Multiple records that all need pruning.
		{
			records_before => [
				{
					file          => '/dir/test.txt',
					checksum      => '123',
					checksum_time => 5,
					modified_time => 1,
					ok            => 1,
				},
				{
					file          => '/dir/test2.txt',
					checksum      => '123',
					checksum_time => 5,
					modified_time => 1,
					ok            => 1,
				},
			],
			unixtime      => 10,
			pruned        => 2,
			records_after => {
			},
		},

		# TODO: Some records to prune, some to not.
	);

	my $db_file = File::Temp::tmpnam();

	my $failures = 0;

	TEST: foreach my $test (@tests) {
		my $dbh = Checksummer::Database::open_db($db_file);
		if (!$dbh) {
			print "test_prune_database: Cannot open database\n";
			$failures++;
			return undef;
		}

		if (!_insert_db_records($dbh, $test->{ records_before })) {
			print "test_prune_database: Unable to perform database updates.\n";
			$failures++;
			unlink $db_file;
			next;
		}

		my $pruned_count = Checksummer::Database::prune_database($dbh,
			$test->{ unixtime });

		if ($pruned_count != $test->{ pruned }) {
			print "test_prune_database: pruned count = $pruned_count, wanted $test->{ pruned }\n";
			$failures++;
			unlink $db_file;
			next;
		}

		my $records = get_all_db_records($dbh);
		if (!$records) {
			print "test_prune_database: error retrieving records\n";
			$failures++;
			unlink $db_file;
			next;
		}

		unlink $db_file;

		if (scalar(@$records) != keys(%{ $test->{ records_after } })) {
			print "test_prune_database: unexpected number of records after test, wanted "
				. scalar(keys(%{ $test->{ records_after } })) . ", got "
				. scalar(@$records) . "\n";
			$failures++;
			next;
		}

		my %file_to_record;
		foreach my $record (@$records) {
			$file_to_record{$record->{file}} = $record;
		}

		foreach my $key (keys %{ $test->{ records_after } }) {
			if (!exists $file_to_record{ $key }) {
				print "FAILURE: prune_database(): record for file not found: $key\n";
				$failures++;
				next TEST;
			}

			my $wanted = $test->{ records_after }{ $key };
			my $got = $file_to_record{ $key };

			if ($wanted->{ checksum } ne $got->{ checksum }) {
				print "FAILURE: prune_database(): record after: $key: checksum = $got->{ checksum }, wanted $wanted->{ checksum }\n";
				$failures++;
				next TEST;
			}

			if ($wanted->{ checksum_time } ne $got->{ checksum_time }) {
				print "FAILURE: prune_database(): record after: $key: checksum_time = $got->{ checksum_time }, wanted $wanted->{ checksum_time }\n";
				$failures++;
				next TEST;
			}
		}
	}

	if ($failures == 0) {
		return 1;
	}

	print "$failures/" . scalar(@tests) . " prune_database tests failed\n";
	return 0;
}

# Package Checksummer::Util tests
sub test_util {
	my $failures = 0;

	if (!test_util_calculate_checksum()) {
		$failures++;
	}

	if (!test_util_mtime()) {
		$failures++;
	}

	return $failures == 0;
}

sub test_util_calculate_checksum {
	my @tests = (
		{
			input       => '123',
			md5_hash    => '202cb962ac59075b964b07152d234b70',
		},
	);

	my $failures = 0;

	my $tmpfile = File::Temp::tmpnam();

	foreach my $test (@tests) {
		# The file shouldn't exist yet.
		my $r = Checksummer::Util::calculate_checksum($tmpfile);
		if (defined $r) {
			print "test_util_calculate_checksum: Failure: File does not exist, yet received checksum\n";
			$failures++;
			next;
		}

		if (!write_file($tmpfile, $test->{ input })) {
			print "test_util_calculate_checksum: Unable to write file\n";
			$failures++;
			next;
		}

		$r = Checksummer::Util::calculate_checksum($tmpfile);
		if (!defined $r) {
			print "calculate_checksum($tmpfile, md5): Unable to calculate checksum\n";
			$failures++;
			unlink $tmpfile;
			next;
		}

		my $sum = unpack('H*', $r);
		if ($sum ne $test->{ md5_hash}) {
			print "calculate_checksum($tmpfile, md5) = $sum, wanted $test->{ md5_hash }\n";
			$failures++;
			unlink $tmpfile;
			next;
		}

		unlink $tmpfile;
	}

	if ($failures == 0) {
		return 1;
	}

	print "$failures/" . (scalar(@tests)) . " test_util_calculate_checksum tests failed\n";
	return 0;
}

sub test_util_mtime {
	my $tmpfile = File::Temp::tmpnam();

	if (!write_file($tmpfile, 'hi')) {
		return 0;
	}

	my $mtime = Checksummer::Util::mtime($tmpfile);
	if (!defined $mtime) {
		print "test_util_mtime: mtime is not defined\n";
		unlink $tmpfile;
		return 0;
	}

	my $now = time;
	if ($mtime != $now && $mtime != $now-1) {
		print "test_util_mtime: unexpected mtime of file\n";
		unlink $tmpfile;
		return 0;
	}

	if (!unlink $tmpfile) {
		print "test_util_mtime: unlink failed: $tmpfile: $!\n";
		return 0;
	}

	return 1;
}

sub write_file {
	my ($filename, $contents) = @_;
	# Permit contents to be blank.
	if (!defined $filename || length $filename == 0 ||
		!defined $contents) {
		print "write_file: Invalid parameter\n";
		return 0;
	}

	my $fh;
	if (!open $fh, '>', $filename) {
		print "write_file: Unable to open file: $filename: $!\n";
		return 0;
	}

	if (!print { $fh } $contents) {
		print "write_file: Failure: Unable to write to file: $filename\n";
		return 0;
	}

	if (!close $fh) {
		print "write_file: Close failure: $filename\n";
		return 0;
	}

	return 1;
}

sub get_all_db_records {
	my ($dbh) = @_;
	if (!$dbh) {
		print "get_all_db_records: You must provide a database handle\n";
		return undef;
	}

	my $sql = q/
	SELECT
	id, file, checksum, checksum_time, modified_time, ok
	FROM checksums
	ORDER BY file
/;
	my @params;

	my $rows = Checksummer::Database::db_select($dbh, $sql, \@params);
	if (!$rows) {
		print "get_all_db_records: Select failure\n";
		return undef;
	}

	my @records;

	foreach my $row (@{ $rows }) {
		push @records, {
			id            => $row->[0],
			file          => $row->[1],
			checksum      => $row->[2],
			checksum_time => $row->[3],
			modified_time => $row->[4],
			ok            => $row->[5],
		};
	}

	return \@records;
}

sub _insert_db_records {
	my ($dbh, $records) = @_;
	if (!$dbh || !$records) {
		print "_insert_db_records: Invalid argument\n";
		return 0;
	}

	my $sql = q/
	INSERT INTO checksums
	(file, checksum, checksum_time, modified_time, ok)
	VALUES(?, ?, ?, ?, ?)
/;
	foreach my $record (@$records) {
		if (!$dbh->do(
				$sql,
				undef,
				$record->{file},
				$record->{checksum},
				$record->{checksum_time},
				$record->{modified_time},
				$record->{ok})) {
			print "_insert_db_records: Error inserting: " . $dbh->errstr . "\n";
			return 0;
		}
	}

	return 1;
}

exit(main() ? 0 : 1);
