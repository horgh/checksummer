#
# This program is for checking for file corruption.
#
# It works by gathering checksums for all files in configured paths. It compares
# the checksum for each file with the checksum stored in a database. If it is
# different, and if the program determines this is erroneous, it reports it.
#
# Its main heuristic is to check if a file's modified time indicates the file
# should not have changed. This is not guaranteed to be correct.
#
# A better solution would be to use a filesystem like ZFS. However, this program
# can help if that is not an option.
#

use strict;
use warnings;

use DBI qw//;
use Digest::MD5 qw//;
use Digest::SHA qw//;
use File::stat qw//;
use Getopt::Std qw//;

$| = 1;

# Boolean. Whether to show debug output.
my $DEBUG = 0;

# Program entry.
#
# Returns: Boolean, whether we completed successfully.
sub main {
	my $args = &_get_args;
	if (!$args) {
		return 0;
	}

	$DEBUG = $args->{ debug };

	my $start = time;

	my $dbh = DBI->connect('dbi:SQLite:dbname=' . $args->{ dbfile }, '', '');
	if (!$dbh) {
		error($DBI::errstr);
		return 0;
	}

	# Use a transaction for faster bulk inserts.
	if (!$dbh->begin_work) {
		error("Unable to start transaction: " . $dbh->errstr);
		return 0;
	}

	if (!&create_schema_if_needed($dbh)) {
		error("Failed to create database schema.");
		$dbh->rollback;
		return 0;
	}

	my $config = &read_config($args->{ config });
	if (!$config) {
		error('Failure reading config.');
		$dbh->rollback;
		return 0;
	}

	if (!@{ $config->{ paths }}) {
		error('No paths found to checksum.');
		$dbh->rollback;
		return 0;
	}

	info("Loading checksums...");

	my $db_checksums = &get_db_checksums($dbh);
	if (!$db_checksums) {
		error("Unable to load current checksums.");
		$dbh->rollback;
		return 0;
	}

	info("Checking files...");

	my $new_checksums = &check_files($config->{ paths }, $args->{ method },
				$config->{ exclusions }, $db_checksums);
	if (!$new_checksums) {
		error('Failure performing file checks.');
		$dbh->rollback;
		return 0;
	}

	if (!&db_updates($dbh, $db_checksums, $new_checksums)) {
		error("Unable to perform database updates.");
		$dbh->rollback;
		return 0;
	}

	if (!$dbh->commit) {
		error("Unable to commit transaction: " . $dbh->errstr);
		return 0;
	}

	my $end = time;
	my $seconds = $end - $start;

	my $minutes = $seconds/60;
	my $hours = int($minutes/60);

	$minutes = $minutes%60;
	$seconds = $seconds%60;

	info("Finished. Runtime: ${hours}h${minutes}m${seconds}s.");
	return 1;
}

sub _get_args {
	my %args;
	if (!Getopt::Std::getopts('hd:c:m:v', \%args)) {
		error("Invalid option.");
		return undef;
	}

	if (exists $args{ h }) {
		&_print_usage;
		return undef;
	}

	if (!exists $args{ d } ||
		length $args{ d } == 0) {
		error("You must provide a database file.");
		&_print_usage;
		return undef;
	}
	my $dbfile = $args{ d };

	if (!exists $args{ c } ||
		length $args{ c } == 0) {
		error("You must provide a config file.");
		&_print_usage;
		return undef;
	}
	my $config = $args{ c };

	if (!exists $args{ m } || length $args{ m } == 0) {
		error("Please choose a hash method.");
		&_print_usage;
		return undef;
	}
	my $method = $args{ m };

	if ($method ne 'sha256' && $method ne 'md5') {
		error("Please select 'sha256' or 'md5' hash method.");
		&_print_usage;
		return undef;
	}

	my $debug = 0;
	if (exists $args{ v }) {
		$debug = 1;
	}

	return {
		dbfile => $dbfile,
		config => $config,
		method => $method,
		debug	 => $debug,
	};
}

sub _print_usage {
	print "Usage: $0 <arguments>

    [-h]           Print this usage information.

    -d <path>      Path to an sqlite3 database to use to store paths and checksums.

                   If the database does not yet exist, it will be created.

    -c <path>      Path to a config file listing directories to examine.

                   Each line should be a path to a directory to check.

                   We ignore blank lines and # comments.

                   If you prefix the path with ! it will exclude it from reports about
                   checksum mismatches. You can ignore paths or specific files this way.
                   It is a substring match applied to the beginning of the filename.

    -m <string>    Hash method to use. Either 'sha256' or 'md5'.

    [-v]           Enable verbose/debug output.

";
}

# Create our schema if it does not already exist.
#
# Parameters:
#
# $dbh, DBI object.
#
# Returns: Boolean, whether successful.
sub create_schema_if_needed {
	my ($dbh) = @_;
	if (!$dbh) {
		error("invalid parameter");
		return 0;
	}

	my $checksum_sql = q/
CREATE TABLE checksums (
id INTEGER PRIMARY KEY,
file NOT NULL,
checksum NOT NULL,
UNIQUE(file)
)
/;
	if (!&create_table_if_not_exists($dbh, 'checksums', $checksum_sql)) {
		error("failure creating table: checksums");
		return 0;
	}

	return 1;
}

# Create the given table if it does not already exist
#
# Parameters:
#
# $dbh, DBI object.
#
# $table, string. The table name.
#
# $table_sql, string. The SQL to use to create the table.
#
# Returns: Boolean, whether successful.
sub create_table_if_not_exists {
	my ($dbh, $table, $table_sql) = @_;
	if (!$dbh ||
		!defined $table || length $table == 0 ||
		!defined $table_sql || length $table_sql == 0) {
		error("invalid arguments");
		return 0;
	}

	# Check if the table exists
	my $sql = q/
SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?
/;
	my @params = ($table,);

	my $rows = &db_select($dbh, $sql, \@params);
	if (!$rows) {
		error("failure selecting table from db");
		return 0;
	}

	# There is a row in the result if it exists
	return 1 if @{ $rows } > 0;

	# Create the table
	info("Creating table: $table");
	return &db_manipulate($dbh, $table_sql, []) != -1;
}

# Read config file to get paths we want to checksum
#
# Parameters:
#
# $path, string. Path to the configuration file.
#
# Returns: A hash reference, or undef if there is a failure.
#
# The hash reference will have these keys:
#
# paths - Array reference of paths to checksum
# exclusions - Array of path prefixes to exclude.
sub read_config {
	my ($path) = @_;
	if (!defined $path || length $path == 0) {
		error("No config file given.");
		return undef;
	}

	if (! -e $path) {
		error("config file does not exist: $path");
		return undef;
	}

	if (! -r $path) {
		error("cannot read config file: $path");
		return undef;
	}

	my $fh;
	if (!open $fh, '<', $path) {
		error("failure opening config file: $path: $!");
		return undef;
	}

	my @paths;
	my @exclusions;

	while (my $line = <$fh>) {
		if (!defined $line) {
			error("failed reading line: $!");
			close $fh;
			return undef;
		}

		chomp $line;

		# Ignore comments and blank lines
		next if $line =~ /^#/ || $line =~ /^\s*$/;

		if (index($line, '/') == 0) {
			push @paths, $line;
			next;
		}

		# It may be excluding a file.
		if (index($line, '!') == 0) {
			push @exclusions, substr($line, 1);
			next;
		}

		error("Unexpected config line: $line");
		return undef;
	}

	if (!close $fh) {
		error("Failure closing config");
		return undef;
	}

	return {
		paths      => \@paths,
		exclusions => \@exclusions,
	};
}

# Load all current checksums from the database into memory.
#
# Keyed by file path.
#
# I'm doing this up front as an optimization.
#
# Parameters:
#
# $dbh, DBI object.
#
# Returns: A hash reference, or undef if failure.
#
# The hash will have keys that are filenames, with the values being the checksum
# for the file.
sub get_db_checksums {
	my ($dbh) = @_;
	if (!$dbh) {
		error("You must provide a database handle");
		return undef;
	}

	my $sql = q/SELECT file, checksum FROM checksums/;
	my @params = ();

	my $rows = &db_select($dbh, $sql, \@params);
	if (!$rows) {
		error("Select failure");
		return undef;
	}

	my %checksums;

	foreach my $row (@{ $rows }) {
		$checksums{ $row->[0] } = $row->[1];
	}

	return \%checksums;
}

# Check all files.
#
# For every path we will recursively descend and perform a checksum upon each
# file found.
#
# If the file exists in the database, compare the checksum with found checksum.
# If not match, warn If it does not exist in the database, add it
#
# Parameters:
#
# $paths, array reference. Array of strings which are paths to check.
#
# $hash_method, string. sha256 or md5. Which hash function to use.
#
# $exclusions, array reference. Array of strings. These are paths to not check.
#
# Returns: An array reference, or undef if failure.
#
# The array is filled with hash references. Each hash reference indicates the
# file and current checksum for the file. An element will only be present if
# the file's checksum changed. The hash reference has keys file and checksum.
sub check_files {
	my ($paths, $hash_method, $exclusions, $db_checksums) = @_;
	if (!$paths ||
		!defined $hash_method || length $hash_method == 0 ||
		!$db_checksums) {
		error("invalid parameter");
		return undef;
	}

	my @new_checksums;

	foreach my $path (@{ $paths }) {
		# Paths must be absolute
		if ($path !~ /\//) {
			error("Invalid path found. Not absolute: $path");
			return undef;
		}

		# Must be a directory
		if (! -e $path || ! -d $path) {
			error("directory does not exist or is not a directory: $path");
			return undef;
		}

		# And must be readable
		if (! -r $path) {
			error("cannot read directory $path");
			return 0;
		}

		info("Checking [$path]...");

		# Recursively descend and look at each file
		my $path_checksums = &check_file($path, $hash_method, $exclusions,
			$db_checksums);
		if (!$path_checksums) {
			error("Problem checking path: $path");
			return undef;
		}

		push @new_checksums, @{ $path_checksums };
	}

	return \@new_checksums;
}

# Examine each file and compare its checksum as described in the
# comment of check_files
#
# Parameters:
#
# $hash_method, string. sha256 or md5. The hash function to use.
#
# $exclusions, array reference. An array of file path prefixes to skip checking.
#
# Returns: An array reference, or undef if failure.
#
# The array may be empty. If it is not, it will contain one element, a hash
# reference. This hash reference means the file's checksum changed. It has keys
# file and checksum.
sub check_file {
	my ($path, $hash_method, $exclusions, $db_checksums) = @_;

	# Optimization: I am not checking parameters here any more.

	# If the config excludes this file then don't even look at it.
	foreach my $exclusion (@{ $exclusions }) {
		if (index($path, $exclusion) == 0) {
			debug('debug', "Ignoring excluded file: $path (Exclusion: $exclusion)");
			return [];
		}
	}

	# We only checksum regular files. Don't bother with symlinks.

	# Skip symlinks. Note -f alone is not sufficient to tell.
	if (-l $path) {
		return [];
	}

	if (! -r $path) {
		error("Warning: cannot read file: $path");
		return [];
	}

	if (-d $path) {
		debug('debug', "$path...");

		my $dh;
		if (!opendir $dh, $path) {
			error("Unable to open dir: $path: $!");
			return undef;
		}

		my @dir_checksums;
		while (my $file = readdir $dh) {
			next if $file eq '.' || $file eq '..';

			my $full_path = $path . '/' . $file;

			my $file_checksums = &check_file($full_path, $hash_method, $exclusions,
				$db_checksums);
			if (!$file_checksums) {
				error("Unable to checksum: $full_path");
				closedir $dh;
				return undef;
			}

			push @dir_checksums, @{ $file_checksums };
		}

		closedir $dh;

		return \@dir_checksums;
	}

	if (! -f $path) {
		return [];
	}

	# At this point we are dealing with a regular file.

	my $checksum = &calculate_checksum($path, $hash_method);
	if (!defined $checksum) {
		error("Failure building checksum for $path");
		return undef;
	}

	# No checksum in the database? Add it. This is the first time we've seen the
	# file.
	if (!defined $db_checksums->{ $path }) {
		debug('debug', "No checksum found in database for $path, adding");
		return [{ file => $path, checksum => $checksum }];
	}

	# If checksum matches then there is nothing to do.
	if ($checksum eq $db_checksums->{ $path }) {
		return [];
	}

	# Checksum does not match. do something.
	&handle_mismatch($path, $checksum, $db_checksums->{ $path });

	# Ensure we store the new checksum.
	return [{ file => $path, checksum => $checksum }];
}

# Build checksum for a given file.
#
# Parameters:
#
# $file, string. The path to the file.
#
# $hash_method, string. sha256 or md5. The hash function to use.
#
# Returns: A string, the checksum, or undef if failure.
sub calculate_checksum {
	my ($file, $hash_method) = @_;

	# Optimization: I am not checking parameters here any more.

	if ($hash_method eq 'sha256') {
		my $sha = Digest::SHA->new(256);

		# I used to use portable mode (m). Doesn't seem useful.

		# b is binary mode.
		$sha->addfile($file, 'b');

		# I used to use b64digest, and then hexdigest.

		# I am making an assumption that digest() is faster though, so I use that
		# now.
		return $sha->digest;
	}

	my $md5 = Digest::MD5->new;

	my $fh;
	if (!open $fh, '<', $file) {
		error("Unable to open file: $file: $!");
		return undef;
	}

	if (!binmode $fh) {
		error("Unable to set binmode: $file: $!");
		close $fh;
		return undef;
	}

	# addfile() croaks on failure.
	$md5->addfile($fh);

	if (!close $fh) {
		error("Unable to close: $file: $!");
		return undef;
	}

	return $md5->digest;
}

# Run actions taken when a checksum mismatch is found
#
# Parameters:
#
# $file, string. The file's path
#
# $checksum, string. The new checksum.
#
# $old_checksum, string. The old checksum.
#
# Returns: None
sub handle_mismatch {
	my ($file, $checksum, $old_checksum) = @_;

	# Optimization: I am not checking parameters here any more.

	debug('debug', "CHECKSUM MISMATCH: $file");

	# Check the last modified date
	# It is probable that this mismatch is due to an actual modification taking
	# place.
	my $st = File::stat::stat($file);
	if (!$st) {
		error("stat failure: $!");
		return;
	}

	my $mtime = $st->mtime;
	my $current_time = time;
	my $one_day_ago = $current_time - 24 * 60 * 60;

	# We have a changed checksum.

	# If the modified time is less than a day ago, then let's assume it
	# was a regular modification that is OK and we don't need to report it.
	#
	# Why? Because we expect this script to be run once a day, so changes
	# within that period are expected.
	#
	# If the recorded modified time was more than a day ago, and we still
	# have a checksum change, then something might be fishy. Not guaranteed.

	if ($mtime < $one_day_ago) {
		info("Checksum mismatch for a file with modified time more than"
			. " a day ago: $file Last modified: " . scalar(localtime($mtime)));
	}
}

# Bulk INSERT/UPDATE the database with the files and checksums we have found
# either new or changed.
sub db_updates {
	my ($dbh, $old_checksums, $new_checksums) = @_;
	if (!$dbh || !$old_checksums || !$new_checksums) {
		error("Invalid parameter");
		return 0;
	}

	my $insert_sql = q/INSERT INTO checksums (file, checksum) VALUES(?, ?)/;
	my $update_sql = q/UPDATE checksums SET checksum = ? WHERE file = ?/;

	my $insert_sth = $dbh->prepare($insert_sql);
	if (!$insert_sth) {
		error("Failure preparing SQL: $insert_sql: " . $dbh->errstr);
		return 0;
	}
	my $update_sth = $dbh->prepare($update_sql);
	if (!$update_sth) {
		error("Failure preparing SQL: $update_sql: " . $dbh->errstr);
		return 0;
	}

	foreach my $file_and_checksum (@{ $new_checksums }) {
		my $file = $file_and_checksum->{ file };
		my $checksum = $file_and_checksum->{ checksum };

		if (exists $old_checksums->{ $file }) {
			my $update_res = $update_sth->execute($checksum, $file);
			if (!defined $update_res) {
				error("Unable to update database for file $file: " . $update_sth->errstr);
				return 0;
			}
			next;
		}

		my $insert_res = $insert_sth->execute($file, $checksum);
		if (!defined $insert_res) {
				error("Unable to insert into database for file $file: " .
					$insert_sth->errstr);
				return 0;
		}
	}

	return 1;
}

# Output a message at info level.
#
# Parameters:
#
# $msg, string. The message to write.
#
# Returns: None
sub info {
	my ($msg) = @_;
	if (!defined $msg) {
		return;
	}
	&debug('info', $msg);
}

# Output a message at error level.
#
# Parameters:
#
# $msg, string. The message to write
#
# Returns: None
sub error {
	my ($msg) = @_;
	debug('error', $msg);
}

# Parameters:
#
# $level, string. debug, info, or error. The log level.
#
# $msg, string. The message to write
#
# Returns: None
sub debug {
		my ($level, $msg) = @_;
		if (!defined $level) {
			&stderr("debug: No level specified.");
			return;
		}
		if (!defined $msg) {
			&stderr("debug: No message given.");
			return;
		}

		if (!$DEBUG && $level eq 'debug') {
				return;
		}

		chomp $msg;
		my $caller = (caller(1))[3];
		if ($caller =~ 'info' || $caller =~ 'error') {
			$caller = (caller(2))[3];
		}

		my $output = "$caller: $msg";

		if ($level =~ /error/i) {
				&stderr($output);
		} else {
				&stdout($output);
		}
}

# Parameters:
#
# $msg, a string, the message to write.
#
# Returns: None
sub stdout {
	my ($msg) = @_;
	if (!defined($msg)) {
		print { \*STDOUT } "\n";
		return;
	}

	chomp $msg;
	print { \*STDOUT } "$msg\n";
}

# Parameters:
#
# $msg, a string, the message to write.
#
# Returns: None
sub stderr {
	my ($msg) = @_;
	if (!defined($msg)) {
		print { \*STDERR } "\n";
		return;
	}

	chomp $msg;
	print { \*STDERR } "$msg\n";
}

sub db_select {
	my ($dbh, $sql, $params) = @_;

	my $sth = $dbh->prepare($sql);
	if (!$sth) {
		error("Failure preparing SQL: $sql: " . $dbh->errstr);
		return undef;
	}

	my $res = $sth->execute(@{ $params });
	if (!defined $res) {
		error("execute(): $sql: " . $dbh->errstr);
		return undef;
	}

	my $rows = $sth->fetchall_arrayref;

	if ($dbh->err) {
		error("Failure fetching results: $sql: " . $dbh->errstr);
		return undef;
	}

	return $rows;
}

sub db_manipulate {
	my ($dbh, $sql, $params) = @_;

	my $sth = $dbh->prepare($sql);
	if (!$sth) {
		error("Failure preparing SQL: $sql: " . $dbh->errstr);
		return undef;
	}

	my $res = $sth->execute(@{ $params });
	if (!defined $res) {
		error("execute(): $sql: " . $dbh->errstr);
		return undef;
	}

	return $sth->rows;
}

exit(&main ? 0 : 1);
