checksummer is a program to monitor files for [silent
corruption](https://en.wikipedia.org/wiki/Data_degradation).

In order to determine that a file is corrupt, the program uses heuristics. This
means what it reports is not guaranteed to be correct. It makes a best effort to
alert of corruption.

Its main heuristic relies on checksums. When run, it computes checksums for all
files under configured directories. It compares the newly computed checksum
with one found in a database for the file. This reveals whether the file
changed since the last run. If the file changed, it uses the file's
modification time to decide whether the modification is legitimate. If the file
changed and its modification time is prior to when checksummer last computed
the checksum, then this is an indication the file is potentially suffering
corruption. If the modification time is after the last time the program
computed the checksum, then it assumes the modification was legitimate.

To best benefit from these checks, you must regularly run checksummer to monitor
your files.

A better solution than using this program would be to use a filesystem such as
[ZFS](https://en.wikipedia.org/wiki/ZFS) which checksums at the filesystem
level. This program can help if that is not an option.


# Dependencies
  * Perl 5
  * [DBI](http://dbi.perl.org/)
  * DBD::SQLite (`libdbd-sqlite3-perl` in Debian)
  * SQLite 3


# Usage/setup
  * Copy `checksummer.conf.sample` and edit it. Enter any paths you want to
    monitor. checksummer recursively descends all directories you specify.
  * Run the program. For example:

        perl checksummer.pl -d checksummer.db -c checksummer.conf -m md5

  * It creates the database automatically if it does not exist.
  * Run it periodically, such as from cron, to monitor files.


# Database interaction
The program creates and updates the database without any manual interaction.

If you want to manually examine checksums in the database, this query may be
useful:

sqlite> SELECT file, hex(checksum) FROM checksums;

This is to show the checksum as hex characters rather than the raw binary data.
