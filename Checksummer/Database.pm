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

	# Explanation of columns:
	# file: Absolute path to the file.
	# checksum: Binary checksum of the file.
	# checksum_time: Unixtime when the checksum was calculated.
	my $table_sql = q/
CREATE TABLE checksums (
  id INTEGER PRIMARY KEY,
  file NOT NULL,
  checksum NOT NULL,
  checksum_time INTEGER NOT NULL,
  UNIQUE(file)
)
/;

	my $r = &db_manipulate($dbh, $table_sql, []);
	if (!defined $r) {
		error("Unable to create table $table_name");
		return 0;
	}

	# We query subsets of rows based on the file path.
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

# Load all current records about files from the database.
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
# The hash will have keys that are filenames. The values will be a hash
# reference with keys checksum and checksum_time.
sub get_db_records {
	my ($dbh, $path) = @_;
	if (!$dbh) {
		error("You must provide a database handle");
		return undef;
	}

	# Let path be empty. This retrieves all.
	$path = '' if !defined $path;

	my $path_sql = &escape_like_parameter($path);
	$path_sql .= '/%';

	my $sql = q/
	SELECT file, checksum, checksum_time
	FROM checksums
	WHERE file LIKE ? ESCAPE '\\'/;
	my @params = ($path_sql);

	my $rows = &db_select($dbh, $sql, \@params);
	if (!$rows) {
		error("Select failure");
		return undef;
	}

	my %checksums;

	foreach my $row (@{ $rows }) {
		$checksums{ $row->[0] } = {
			checksum      => $row->[1],
			checksum_time => $row->[2],
		},
	}

	return \%checksums;
}

# LIKE treats certain characters specially. Escape them.
#
# This assumes the escape character is \.
sub escape_like_parameter {
	my ($s) = @_;
	if (!defined $s) {
		return '';
	}

	$s =~ s/\\/\\\\/g;
	$s =~ s/_/\\_/g;
	$s =~ s/%/\\%/g;

	return $s;
}

# Bulk INSERT/UPDATE the database with the files and checksums we have found
# either new or changed.
sub update_db_records {
	my ($dbh, $old_records, $new_records) = @_;
	if (!$dbh || !$old_records|| !$new_records) {
		error("Invalid parameter");
		return 0;
	}

	my $insert_sql = q/
	INSERT INTO checksums
	(file, checksum, checksum_time) VALUES(?, ?, ?)/;
	my $update_sql = q/
	UPDATE checksums
	SET checksum = ?, checksum_time = ?
	WHERE file = ?/;

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

	foreach my $c (@{ $new_records }) {
		if (exists $old_records->{ $c->{ file } }) {
			my $update_res = $update_sth->execute($c->{ checksum },
				$c->{ checksum_time }, $c->{ file });
			if (!defined $update_res) {
				error("Unable to update database for file $c->{ file }: "
					. $update_sth->errstr);
				$dbh->rollback;
				return 0;
			}

			next;
		}

		my $insert_res = $insert_sth->execute($c->{ file }, $c->{ checksum },
			$c->{ checksum_time });
		if (!defined $insert_res) {
			error("Unable to insert into database for file $c->{ file }: " .
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

# We just recomputed checksums for all files that currently exist. There may be
# files in the database that were deleted. Delete any rows that have times prior
# to the given time. The given time should be prior to computing the new set of
# checksums.
sub prune_database {
	my ($dbh, $unixtime) = @_;
	if (!$dbh || !defined $unixtime) {
		error("Invalid parameter");
		return -1;
	}

	my $sql = q/DELETE FROM checksums WHERE checksum_time < ?/;

	my $rows_affected = $dbh->do($sql, undef, $unixtime);
	if (!defined $rows_affected) {
		error("Unable to delete rows: " . $dbh->errstr);
		return -1;
	}

	# DBI returns 0 as 0E0.
	if ($rows_affected == 0) {
		$rows_affected = 0;
	}

	return $rows_affected;
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
