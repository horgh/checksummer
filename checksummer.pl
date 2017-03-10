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

use Checksummer qw//;
use Checksummer::Util qw/info error/;
use Getopt::Std qw//;

$| = 1;

# Program entry.
#
# Returns: Boolean, whether we completed successfully.
sub main {
	my $args = &_get_args;
	if (!$args) {
		return 0;
	}

	Checksummer::Util::set_debug($args->{ debug });

	my $config = Checksummer::read_config($args->{ config });
	if (!$config) {
		error('Failure reading config.');
		return 0;
	}

	my $start = time;

	my $new_checksums = Checksummer::run($args->{ db_file },
		$args->{ hash_method }, $config);
	if (!$new_checksums) {
		error("Failure running checks.");
		return 0;
	}

	my $end = time;

	my $runtime_in_seconds = $end - $start;

	my $runtime_in_minutes = $runtime_in_seconds/60;

	my $runtime_in_hours = int($runtime_in_minutes/60);

	$runtime_in_minutes = $runtime_in_minutes%60;
	$runtime_in_seconds = $runtime_in_seconds%60;

	info("Finished. Runtime: ${runtime_in_hours}h${runtime_in_minutes}m${runtime_in_seconds}s.");
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
	my $db_file = $args{ d };

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
	my $hash_method = $args{ m };

	if ($hash_method ne 'sha256' && $hash_method ne 'md5') {
		error("Please select 'sha256' or 'md5' hash method.");
		&_print_usage;
		return undef;
	}

	my $debug = 0;
	if (exists $args{ v }) {
		$debug = 1;
	}

	return {
		db_file     => $db_file,
		config      => $config,
		hash_method => $hash_method,
		debug	      => $debug,
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

exit(&main ? 0 : 1);
