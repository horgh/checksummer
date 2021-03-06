# Functions for interaction with the database.

use strict;
use warnings;

package Checksummer::Database;

use Checksummer::Util qw/info error/;

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

	if (!create_schema_if_needed($dbh)) {
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

	if (table_exists($dbh, $table_name)) {
		return 1;
	}

	info("Creating table [$table_name]");

	# Explanation of columns:
	# - file: Absolute path to the file.
	# - checksum: Binary checksum of the file.
	# - checksum_time: Unixtime when the checksum was calculated. We use this to
	#   know that the file can be pruned from the database if it gets deleted.
	#   This can potentially be removed. I believe we can do pruning without it.
	#   Previously I used it in the heuristics for deciding whether a checksum
	#   change was problematic, but no longer. It may still be interesting to
	#   track though.
	# - modified_time: Unixtime of the file last time we calculated its checksum.
	#   We use this for our heuristics around whether a checksum change is a
	#   problem.
	# - ok: Whether the last time the file was checked we thought there was a
	#   problem.
	my $table_sql = q/
CREATE TABLE checksums (
  id INTEGER PRIMARY KEY,
  file NOT NULL,
  checksum NOT NULL,
  checksum_time INTEGER NOT NULL,
  modified_time INTEGER NOT NULL,
  ok BOOLEAN NOT NULL,
  UNIQUE(file)
)
/;

	my $r = db_manipulate($dbh, $table_sql, []);
	if (!defined $r) {
		error("Unable to create table $table_name");
		return 0;
	}

	# We query subsets of rows based on the file path.
	my $index_sql = q/CREATE INDEX file_idx ON checksums (file)/;

	$r = db_manipulate($dbh, $index_sql, []);
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

	my $rows = db_select($dbh, $sql, \@params);
	if (!$rows) {
		error("Failure selecting table from db");
		return 0;
	}

	return 1 if @{ $rows } > 0;
	return 0;
}

sub prepare_statements {
	my ($dbh) = @_;
	if (!$dbh) {
		error("Invalid argument");
		return undef;
	}

	my $select_sql = q/
	SELECT file, checksum, checksum_time, modified_time
	FROM checksums WHERE file = ?
/;
	my $select_sth = $dbh->prepare($select_sql);
	if (!$select_sth) {
		error("Error preparing SELECT statement: " . $dbh->errstr);
		return undef;
	}

	my $insert_sql = q/
	INSERT INTO checksums
	(file, checksum, checksum_time, modified_time, ok)
	VALUES(?, ?, ?, ?, ?)
/;
	my $insert_sth = $dbh->prepare($insert_sql);
	if (!$insert_sth) {
		error("Error preparing INSERT statement: " . $dbh->errstr);
		return undef;
	}

	my $update_sql = q/
	UPDATE checksums
	SET checksum = ?, checksum_time = ?, modified_time = ?, ok = ?
	WHERE file = ?
/;
	my $update_sth = $dbh->prepare($update_sql);
	if (!$update_sth) {
		error("Error preparing UPDATE statement: " . $dbh->errstr);
		return undef;
	}

	return {
		select => $select_sth,
		insert => $insert_sth,
		update => $update_sth,
	};
}

# We just recomputed checksums for all files that currently exist. There may be
# files in the database that were deleted. Delete any rows that have times
# prior to the given time. The given time should be prior to computing the new
# set of checksums.
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
