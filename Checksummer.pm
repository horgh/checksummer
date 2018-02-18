# Core checksummer functions.

use strict;
use warnings;

package Checksummer;

use Checksummer::Database qw//;
use Checksummer::Util qw/info error debug/;
use DBI qw//;
use Exporter qw/import/;

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

	while (!eof $fh) {
		my $line = <$fh>;
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

	my %config = (
		paths      => \@paths,
		exclusions => \@exclusions,
	);

	if (!is_valid_config(\%config)) {
		error("Configuration problem");
		return undef;
	}

	return \%config;
}

# Check the configuration values.
#
# Each path and each exclusion must be absolute.
#
# We check that each path given is a directory.
sub is_valid_config {
	my ($config) = @_;
	if (!$config || !exists $config->{ paths } ||
		!exists $config->{ exclusions }) {
		error("Invalid parameter");
		return 0;
	}

	# Each path must be absolute, and it must be an existing directory.
	foreach my $path (@{ $config->{ paths } }) {
		if (index($path, '/') != 0) {
			error("Path is not absolute: $path");
			return 0;
		}

		if (! -e $path) {
			error("Path does not exist: $path");
			return 0;
		}

		if (! -d $path) {
			error("Path is not a directory: $path");
			return 0;
		}
	}

	if (@{ $config->{ paths } } == 0) {
		error("No paths provided. You must provide at least one.");
		return 0;
	}

	# Each exclusion must be an absolute path. It might not exist.
	foreach my $exclusion (@{ $config->{ exclusions } }) {
		if (index($exclusion, '/') != 0) {
			error("Exclusion is not absolute: $exclusion");
			return 0;
		}
	}

	return 1;
}

# Run checks using checksums from a database. We create the database if
# necessary, and update it with any changed or new checksums.
#
# Returns: An array reference containing the files that changed, or undef if
# failure. See check_files() for an explanation of the return value.
sub run {
	my ($db_file, $hash_method, $config, $should_return_checksums) = @_;
	if (!defined $db_file || length $db_file == 0 ||
		!defined $hash_method || length $hash_method == 0 ||
		!$config) {
		error("Invalid parameter");
		return undef;
	}

	my $dbh = Checksummer::Database::open_db($db_file);
	if (!$dbh) {
		error("Cannot open database");
		return undef;
	}

	my $start_time = time;

	my $new_checksums = Checksummer::check_files($dbh, $config->{ paths },
		$hash_method, $config->{ exclusions }, $should_return_checksums);
	if (!$new_checksums) {
		error('Failure performing file checks.');
		return undef;
	}

	my $pruned_count = Checksummer::Database::prune_database($dbh, $start_time);
	if ($pruned_count == -1) {
		error("Unable to prune database of deleted files.");
		return undef;
	}

	info("Pruned $pruned_count database records.");

	return $new_checksums;
}

# Check all files.
#
# For every path we will recursively descend and calculate a checksum for each
# file.
#
# Look up information about the file in the database.
#
# If the file does not exist in the database, add a record for it.
#
# If the file exists in the database, compare the current checksum with the
# database checksum.
#
# If the checksums do not match, analyze whether the mismatch looks valid. If
# it doesn't, warn there is a problem.
#
# Parameters:
#
# $paths, array reference. Array of strings which are paths to check.
#
# $hash_method, string. sha256 or md5. Which hash function to use.
#
# $exclusions, array reference. Array of strings. These are paths to not check.
#
# $should_return_checksums, boolean. Whether to return information about files
# or not. As doing so necessarily requires using memory, you may not wish to do
# this.
#
# Returns: An array reference, or undef if failure.
#
# If you ask to return checksums, then the array is filled with hash
# references. Each hash reference provides the file and current checksum for
# the file. All files under the given path will be present, no matter whether
# the file's checksum changed or not. For information about the format of the
# hash, see check_file().
#
# If you don't ask to return checksums, the array reference will be empty.
sub check_files {
	my ($dbh, $paths, $hash_method, $exclusions,
		$should_return_checksums) = @_;
	if (!$dbh || !$paths || @$paths == 0 || !defined $hash_method ||
		length $hash_method == 0 || !$exclusions) {
		error("Invalid parameter");
		return undef;
	}

	my @new_checksums;

	foreach my $path (@{ $paths }) {
		info("Checking [$path]...");

		# As a memory optimization, load checksums for files from the database
		# under each path rather than all checkums at once. Then update the
		# database with any new checksums under this path, and repeat.

		my $db_records = Checksummer::Database::get_db_records($dbh, $path);
		if (!$db_records) {
			error("Unable to load file information from the database.");
			return undef;
		}

		my $path_checksums = check_file($path, $hash_method, $exclusions,
			$db_records);
		if (!$path_checksums) {
			error("Problem checking path: $path");
			return undef;
		}

		if (!Checksummer::Database::update_db_records($dbh, $db_records,
				$path_checksums)) {
			error("Unable to perform database updates.");
			return undef;
		}

		# Conditionally return the checksums. This is useful for testing, but in
		# real runs this can lead to high memory consumption.
		if ($should_return_checksums) {
			push @new_checksums, @{ $path_checksums };
		}
	}

	return \@new_checksums;
}

# Examine each file and compare its checksum as described by check_files().
# Either examine an individual file or recursively descend and analyze a tree.
#
# Parameters:
#
# $path, string. Path to the file to check. This function determines how to
# deal with the file, so it can be any type (directory, regular file, etc).
#
# $hash_method, string. sha256 or md5. The hash function to use.
#
# $exclusions, array reference. An array of file path prefixes to skip
# checking.
#
# $db_records, hash reference. A hash keyed by file path, including the last
# known checksum and checksum time.
#
# Returns: An array reference, or undef if there was a failure.
#
# The array may be empty. This can happen if the file/path should be excluded
# or is a symbolic link, among other reasons. Elements in the array are hash
# references.
#
# The hash will have keys:
#
# - file (file, string, the path)
#
# - checksum (its hash, binary)
#
# - checksum_time (unixtime prior to calculating the checksum)
#
# - modified_time (unixtime of the file now)
#
# - ok (boolean, true if there was no mismatch problem)
sub check_file {
	my ($path, $hash_method, $exclusions, $db_records) = @_;

	# Optimization: I am not checking parameters here any more.

	if (is_file_excluded($exclusions, $path)) {
		return [];
	}

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

			my $file_checksums = check_file($full_path, $hash_method, $exclusions,
				$db_records);
			if (!$file_checksums) {
				error("Unable to checksum: $full_path");
				closedir $dh;
				return undef;
			}

			push @dir_checksums, @{ $file_checksums };
		}

		if (!closedir $dh) {
			error("closedir failed: $path");
			return undef;
		}

		return \@dir_checksums;
	}

	if (! -f $path) {
		return [];
	}

	# At this point we are dealing with a regular file. Calculate its checksum and
	# potentially raise a warning if there is a problematic mismatch.

	# Gather the newest information about the file. We fill the fields in as we
	# go.
	my %info = (
		file          => $path,
		checksum      => undef,
		checksum_time => undef,
		modified_time => undef,
		ok            => 1,
	);

	# Record the current time prior to calculating the checksum. We use this both
	# for heuristics and for pruning the database of deleted files.
	$info{ checksum_time } = time;

	# Get the file's current mtime. We use it for heuristics.
	$info{ modified_time } = Checksummer::Util::mtime($path);
	if (!defined $info{ modified_time }) {
		# We reported an error already.
		return undef;
	}

	$info{ checksum } = Checksummer::Util::calculate_checksum($path,
		$hash_method);
	if (!defined $info{ checksum }) {
		error("Failure building checksum for $path");
		return undef;
	}

	# Is the file not in the database? Add it. This is the first time we've seen
	# the file.
	if (!exists $db_records->{ $path }) {
		debug('debug', "No checksum found in database for $path, adding");
		return [ \%info ];
	}

	# If the checksums match then there is nothing to do.
	if ($info{ checksum } eq $db_records->{ $path }{ checksum }) {
		return [ \%info ];
	}

	# Decide whether this mismatch is a problem or not. Report if it is.
	my $mismatch_result = checksum_mismatch($path, $db_records->{ $path },
		$info{ modified_time });
	if ($mismatch_result == -1) {
		error("Problem checking checksum mismatch status for $path");
		return undef;
	}

	if ($mismatch_result == 0) {
		return [ \%info ];
	}

	# The mismatch looks problematic.
	$info{ ok } = 0;
	return [ \%info ];
}

# Some paths/files are excluded by the config (prefixed with !).
#
# Check if the path to the file begins with an excluded path.
sub is_file_excluded {
	my ($exclusions, $path) = @_;

	# Optimization: Don't check parameters.

	# If the config excludes this file then don't even look at it.
	foreach my $exclusion (@{ $exclusions }) {
		if (index($path, $exclusion) == 0) {
			debug('debug', "Excluded file: $path (Exclusion: $exclusion)");
			return 1;
		}
	}

	return 0;
}

# The current checksum for the file does not match what we have recorded. We
# check whether this indicates a problem. If it does, we raise a warning. If
# not, we do nothing.
#
# Parameters:
#
# $file, string. The file's path
#
# $db_record, hash reference. Information from the database about the file.
# See get_db_records() for what is in it.
#
# $current_mtime, integer. The modified time (unixtime) of the file right now.
#
# Returns: Integer.
#
# The integer will be 0 if the mismatch looks fine. It will be 1 if there
# appears to be a problem. It will be -1 if there was an error.
sub checksum_mismatch {
	my ($path, $db_record, $current_mtime) = @_;

	# Optimization: I am not checking parameters here any more.

	debug('debug', "CHECKSUM MISMATCH: $path");

	# If the file's current modified time is after the last modified time we have
	# recorded for it, then we say there was a legitimate modification.

	# If it's the same then there is potentially corruption.

	# If it's before then it is probably okay too, but is strange.

	if ($current_mtime > $db_record->{ modified_time }) {
		return 0;
	}

	my $report = sprintf(
		"Suspicious checksum mismatch detected for %s. Current modified time: %s Previously recorded modified time: %s Last time checksum computed: %s\n",
		$path,
		scalar(localtime($current_mtime)),
		scalar(localtime($db_record->{ modified_time })),
		scalar(localtime($db_record->{ checksum_time }))
	);

	info($report);

	return 1;
}

1;
