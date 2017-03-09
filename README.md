checksummer is a program that to monitor files for [silent
corruption](https://en.wikipedia.org/wiki/Data_degradation).

When run, it calculates checksums for all of the files under specified
directories. It compares each checksum with the most recent checksum for each
file, from a database of checksums. If there is a difference that looks
incorrect, it reports that there is a problem. It creates/updates the database
of checksums (SQLite).

In order to determine that a file is corrupt, the program uses heuristics. For
example, if the file's modified time is far in the past, and its checksum today
is different than yesterday, then this is an indication that there is silent
corruption. This is of course not an absolute.

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

  * This creates the database automatically as necessary.
  * You will want to run this in cron. Typically at least once a day, as that
    one of the heuristics currently assumes this.


# Database interaction
The program creates and updates the database without any manual interaction.

If you want to manually examine checksums in the database, this query may be
useful:

sqlite> select file, hex(checksum) from checksums;

This is to show the checksum as hex characters rather than the raw binary data.
