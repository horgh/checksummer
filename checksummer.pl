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
use Checksummer::Database qw//;
use Checksummer::Util qw/info error/;
use DBI qw//;
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

	if (!Checksummer::Database::create_schema_if_needed($dbh)) {
		error("Failed to create database schema.");
		$dbh->rollback;
		return 0;
	}

	my $config = Checksummer::read_config($args->{ config });
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

	my $db_checksums = Checksummer::Database::get_db_checksums($dbh);
	if (!$db_checksums) {
		error("Unable to load current checksums.");
		$dbh->rollback;
		return 0;
	}

	info("Checking files...");

	my $new_checksums = Checksummer::check_files($config->{ paths },
		$args->{ method }, $config->{ exclusions }, $db_checksums);
	if (!$new_checksums) {
		error('Failure performing file checks.');
		$dbh->rollback;
		return 0;
	}

	if (!Checksummer::Database::db_updates($dbh, $db_checksums, $new_checksums)) {
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

exit(&main ? 0 : 1);
