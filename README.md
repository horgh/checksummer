To examine checksums in the database, this may be useful:

sqlite> select file, hex(checksum) from checksums;

This is to show the checksum as hex characters rather than the raw binary data.
