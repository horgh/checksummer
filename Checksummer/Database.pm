#
# Functions for interaction with the database.
#

use strict;
use warnings;

package Checksummer::Database;

use Checksummer::Util qw/info error/;
use Exporter qw/import/;

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

1;
