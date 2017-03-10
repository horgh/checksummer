#
# Functions for interaction with the database.
#

use strict;
use warnings;

package Checksummer::Database;

use Checksummer::Util qw/info error/;
use Exporter qw/import/;

sub open_db {
	my ($file) = @_;
	if (!defined $file || length $file == 0) {
		error("Invalid parameter");
		return undef;
	}

	my $dbh = DBI->connect("dbi:SQLite:dbname=$file", '', '');
	if (!$dbh) {
		error($DBI::errstr);
		return undef;
	}

	if (!&create_schema_if_needed($dbh)) {
		error("Failed to create database schema.");
		return undef;
	}

	# LIKE is case insensitive by default in sqlite. Make it case sensitive.
	if (!$dbh->do('PRAGMA case_sensitive_like = 1')) {
		error("Unable to enable LIKE CASE sensitivity: " . $dbh->errstr);
		return undef;
	}

	return $dbh;
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
		error("Invalid parameter");
		return 0;
	}

	my $table_name = 'checksums';

	if (&table_exists($dbh, $table_name)) {
		return 1;
	}

	info("Creating table [$table_name]");

	my $table_sql = q/
CREATE TABLE checksums (
  id INTEGER PRIMARY KEY,
  file NOT NULL,
  checksum NOT NULL,
  UNIQUE(file)
)
/;

	my $r = &db_manipulate($dbh, $table_sql, []);
	if (!defined $r) {
		error("Unable to create table $table_name");
		return 0;
	}

	my $index_sql = q/CREATE INDEX file_idx ON checksums (file)/;

	$r = &db_manipulate($dbh, $index_sql, []);
	if (!defined $r) {
		error("Unable to create index on table $table_name");
		return 0;
	}

	return 1;
}

# Check if the given table exists in the database.
#
# Parameters:
#
# $dbh, DBI object.
#
# $table, string. The table name.
#
# Returns: Boolean, whether it does.
sub table_exists {
	my ($dbh, $table) = @_; if (!$dbh ||
		!defined $table || length $table == 0) {
		error("Invalid argument");
		return 0;
	}

	my $sql = q/SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?/;
	my @params = ($table);

	my $rows = &db_select($dbh, $sql, \@params);
	if (!$rows) {
		error("Failure selecting table from db");
		return 0;
	}

	return 1 if @{ $rows } > 0;
	return 0;

	# Create the table
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
	my ($dbh, $path) = @_;
	if (!$dbh) {
		error("You must provide a database handle");
		return undef;
	}
	if (!defined $path || length $path == 0) {
		error("You must provide a path");
		return undef;
	}

	my $path_sql = $path;
	$path_sql =~ s/_/\\_/g;
	$path_sql =~ s/%/\\%/g;
	$path_sql .= '%';

	my $sql = q/SELECT file, checksum FROM checksums WHERE file LIKE ? ESCAPE '\\'/;
	my @params = ($path_sql);

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
sub update_db_checksums {
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

	# Use a transaction for faster bulk inserts.
	if (!$dbh->begin_work) {
		error("Unable to start transaction: " . $dbh->errstr);
		return 0;
	}

	foreach my $file_and_checksum (@{ $new_checksums }) {
		my $file = $file_and_checksum->{ file };
		my $checksum = $file_and_checksum->{ checksum };

		if (exists $old_checksums->{ $file }) {
			my $update_res = $update_sth->execute($checksum, $file);
			if (!defined $update_res) {
				error("Unable to update database for file $file: " . $update_sth->errstr);
				$dbh->rollback;
				return 0;
			}

			next;
		}

		my $insert_res = $insert_sth->execute($file, $checksum);
		if (!defined $insert_res) {
			error("Unable to insert into database for file $file: " .
				$insert_sth->errstr);
			$dbh->rollback;
			return 0;
		}
	}

	if (!$dbh->commit) {
		error("Unable to commit transaction: " . $dbh->errstr);
		return 0;
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
