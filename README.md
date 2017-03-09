checksummer is a program that I built so I could monitor files for [silent
corruption](https://en.wikipedia.org/wiki/Data_degradation).

When run, it calculates checksums for all files under specified directories.
It compares these with the most recent checksum for a file, from a database
of checksums. If there is a difference that looks incorrect, it reports that
there is a problem. It creates/updates the database of checksums (SQLite).

In order to determine that a file has silent corruption, the program applies
heuristics. For example, if the file's modified time is far in the past, and
its checksum today is different than yesterday, then this is potentially an
indication that there is silent corruption. This is of course not an absolute.

A better solution than using this program would be to use a filesystem such as
[ZFS](https://en.wikipedia.org/wiki/ZFS) which checksums at the filesystem
level. This program can help if that is not an option.


# Dependencies
  * Perl 5
  * [DBI](http://dbi.perl.org/)


# Database
To examine checksums in the database, this may be useful:

sqlite> select file, hex(checksum) from checksums;

This is to show the checksum as hex characters rather than the raw binary data.
