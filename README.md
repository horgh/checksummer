checksummer is a program to monitor files for [silent
corruption](https://en.wikipedia.org/wiki/Data_degradation).

In order to determine whether a file is corrupt, the program uses
heuristics. This means what it reports is not guaranteed to be correct. It
makes a best effort to alert of corruption.

To best benefit from these checks, you must regularly run checksummer to monitor
your files.

A better solution than using this program would be to use a filesystem such
as [ZFS](https://en.wikipedia.org/wiki/ZFS) to checksum at the filesystem
level. This program can help if that is not an option.


# Checksum heuristic
checksummer's main heuristic relies on checksums. When run, it computes
checksums for all files under configured directories. It compares the newly
computed checksum with the one found in a database for the file. This
reveals whether the file changed since the last run.

If the file changed, checksummer uses the file's modification time to
decide whether the modification is legitimate. (Each time it inspects a
file, it also records the file's last modification time.)

Using these two modification times, checksummer decides whether the
modification is legitimate or suspicious. If the new modification time is
subsequent to that of its last inspection, checksummer assumes the
modification is legitimate. Otherwise the modification time is the same or
prior to the last modification time and checksummer reports this as
suspicious.


# Dependencies
* Perl 5
* [DBI](http://dbi.perl.org/)
* DBD::SQLite (`libdbd-sqlite3-perl` in Debian)
* SQLite 3


# Usage/setup
* Copy `checksummer.conf.sample` and edit it. Enter any paths you want to
  monitor. checksummer recursively descends all directories you specify.
* Run the program. For example:

        perl checksummer.pl -d checksummer.db -c checksummer.conf -p

* It creates the database automatically if it does not exist.
* Run it periodically, such as from cron, to monitor files.
