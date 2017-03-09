#
# Core checksummer functions.
#

package Checksummer;

use Checksummer::Util qw/info error debug/;
use Exporter qw/import/;
use File::stat qw//;

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
# Returns: An array reference, or undef if there was a failure.
#
# The array may be empty. If it is not, it will contain one element, a hash
# reference. This hash reference means the file's checksum changed, and we
# should store the new checksum.
#
# The hash will have keys file (file path, string), checksum, (its hash,
# binary), and ok (boolean, true if there was no mismatch problem).
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

		if (!closedir $dh) {
			error("closedir failed: $path");
			return undef;
		}

		return \@dir_checksums;
	}

	if (! -f $path) {
		return [];
	}

	# At this point we are dealing with a regular file.

	my $checksum = Checksummer::Util::calculate_checksum($path, $hash_method);
	if (!defined $checksum) {
		error("Failure building checksum for $path");
		return undef;
	}

	# No checksum in the database? Add it. This is the first time we've seen the
	# file.
	if (!defined $db_checksums->{ $path }) {
		debug('debug', "No checksum found in database for $path, adding");
		return [{ file => $path, checksum => $checksum, ok => 1 }];
	}

	# If checksum matches then there is nothing to do.
	if ($checksum eq $db_checksums->{ $path }) {
		return [];
	}

	my $mismatch_result = &checksum_mismatch($path, $checksum,
		$db_checksums->{ $path });
	if ($mismatch_result == -1) {
		error("Problem checking mismatch for $path");
		return undef;
	}

	# The mismatch looks problematic.
	if ($mismatch_result == 1) {
		return [{ file => $path, checksum => $checksum, ok => 0 }];
	}

	return [{ file => $path, checksum => $checksum, ok => 1 }];
}

# The current checksum for the file does not match what we have recorded. We
# check whether this indicates a problem. If it does, we raise a warning. If
# not, we do nothing.
#
# Parameters:
#
# $file, string. The file's path
#
# $checksum, string. The new checksum.
#
# $old_checksum, string. The old checksum.
#
# Returns: Integer.
#
# The integer will be 0 if the mismatch looks fine. It will be 1 if there
# appears to be a problem. It will be -1 if there was an error.
sub checksum_mismatch {
	my ($file, $checksum, $old_checksum) = @_;

	# Optimization: I am not checking parameters here any more.

	debug('debug', "CHECKSUM MISMATCH: $file");

	# Check the last modified date It is probable that this mismatch is due to an
	# actual modification taking place.
	my $st = File::stat::stat($file);
	if (!$st) {
		error("stat failure: $!");
		return -1;
	}

	my $mtime = $st->mtime;
	my $current_time = time;
	my $one_day_ago = $current_time - 24 * 60 * 60;

	# If the modified time is less than a day ago, then let's assume it was a
	# regular modification that is OK and we don't need to report it.
	#
	# Why? Because we expect this script to be run once a day, so changes within
	# that period are expected.
	#
	# If the recorded modified time was more than a day ago, then something might
	# be fishy. We assume the file should not have changed.
	#
	# This is not an absolute. It's possible a file had corruption within the past
	# day. It is a heuristic.

	if ($mtime < $one_day_ago) {
		info("Checksum mismatch for a file with modified time more than"
			. " a day ago: $file Last modified: " . scalar(localtime($mtime)));
		return 1;
	}

	return 0;
}

1;
