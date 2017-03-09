#
# Some unit tests.
#

use strict;
use warnings;

use Checksummer qw//;
use Checksummer::Util qw//;
use File::Temp qw//;

sub main {
  my $failures = 0;

  if (!&test_checksummer) {
    print "Checksummer tests failed\n";
    $failures++;
  }

  if (!&test_util) {
    print "Util tests failed\n";
    $failures++;
  }

  if ($failures == 0) {
    print "All tests completed successfully\n";
    return 1;
  }

  print "$failures tests failed\n";
  return 0;
}

# Package Checksummer tests
sub test_checksummer {
  my $failures = 0;

  if (!&test_is_file_excluded) {
    $failures++;
  }

  if (!&test_checksum_mismatch) {
    $failures++;
  }

  return $failures == 0;
}

sub test_is_file_excluded {
  my @tests = (
    # Excluded.
    {
      exclusions => ['/tmp', '/bin'],
      path       => '/tmp/test.txt',
      output     => 1,
    },

    # Not excluded.
    {
      exclusions => ['/tmp', '/bin'],
      path       => '/home/horgh/test.txt',
      output     => 0,
    },
  );

  my $failures = 0;

  foreach my $test (@tests) {
    my $r = Checksummer::is_file_excluded($test->{ exclusions },
      $test->{ path });
    if ($r != $test->{ output }) {
      print "is_file_excluded(@{ $test->{ exclusions } }, $test->{ path }) = $r, wanted $test->{ output }\n";
      $failures++;
      next;
    }
  }

  if ($failures == 0) {
    return 1;
  }

  print "$failures/" . (scalar(@tests)) . " test_is_file_excluded tests failed\n";
  return 0;
}

sub test_checksum_mismatch {
  my $now = time;
  my $one_hour_ago = time - 60*60;
  my $one_week_ago = time - (7*24*60*60);

  my @tests = (
    # The mtime is recent enough that the mismatch is okay.
    {
      file_exists  => 1,
      mtime        => $one_hour_ago,
      output       => 0,
    },

    # The mtime is long enough ago that the mismatch is a problem.
    {
      file_exists  => 1,
      mtime        => $one_week_ago,
      output       => 1,
    },

    # Unable to stat the file.
    {
      file_exists  => 0,
      mtime        => $one_week_ago,
      output       => -1,
    },
  );

  my $failures = 0;

  my $tmpfile = File::Temp::tmpnam();

  # The checksums are irrelevant. The function uses them for reporting only. If
  # it is called, then checksums must have been different.
  my $new_checksum = '123';
  my $old_checksum = '456';

  foreach my $test (@tests) {
    if ($test->{ file_exists }) {
      if (!&write_file($tmpfile, 'hi')) {
        print "test_checksum_mismatch: Unable to write file: $tmpfile\n";
        $failures++;
        next;
      }

      if (utime($test->{ mtime }, $test->{ mtime }, $tmpfile) != 1) {
        print "test_checksum_mismatch: utime failed: $tmpfile\n";
        $failures++;
        next;
      }
    }

    my $r = Checksummer::checksum_mismatch($tmpfile, $new_checksum,
      $old_checksum);
    if ($r != $test->{ output }) {
      print "checksum_mismatch($tmpfile, ...) = $r, wanted $test->{ output }\n";
      $failures++;
      unlink $tmpfile if $test->{ file_exists };
      next;
    }

    if ($test->{ file_exists} && !unlink $tmpfile) {
      print "test_checksum_mismatch: Unable to unlink file: $tmpfile: $!\n";
      $failures++;
      next;
    }
  }

  if ($failures == 0) {
    return 1;
  }

  print "$failures/" . (scalar(@tests)) . " test_checksum_mismatch tests failed\n";
  return 0;
}

# Package Checksummer::Util tests
sub test_util {
  my $failures = 0;

  if (!&test_util_calculate_checksum) {
    $failures++;
  }

  return $failures == 0;
}

sub test_util_calculate_checksum {
  my @tests = (
    {
      input       => '123',
      md5_hash    => '202cb962ac59075b964b07152d234b70',
      sha256_hash => 'a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3',
    },
  );

  my $failures = 0;

  my $tmpfile = File::Temp::tmpnam();

  foreach my $test (@tests) {
    # The file shouldn't exist yet.
    my $r = Checksummer::Util::calculate_checksum($tmpfile, 'md5');
    if (defined $r) {
      print "test_util_calculate_checksum: Failure: File does not exist, yet received checksum\n";
      $failures++;
      next;
    }

    if (!&write_file($tmpfile, $test->{ input })) {
      print "test_util_calculate_checksum: Unable to write file\n";
      $failures++;
      unlink $tmpfile;
      next;
    }

    $r = Checksummer::Util::calculate_checksum($tmpfile, 'md5');
    if (!defined $r) {
      print "calculate_checksum($tmpfile, md5): Unable to calculate checksum\n";
      $failures++;
      unlink $tmpfile;
      next;
    }

    my $sum = unpack('H*', $r);
    if ($sum ne $test->{ md5_hash}) {
      print "calculate_checksum($tmpfile, md5) = $sum, wanted $test->{ md5_hash }\n";
      $failures++;
      unlink $tmpfile;
      next;
    }

    $r = Checksummer::Util::calculate_checksum($tmpfile, 'sha256');
    if (!defined $r) {
      print "calculate_checksum($tmpfile, sha256): Unable to calculate checksum\n";
      $failures++;
      unlink $tmpfile;
      next;
    }

    $sum = unpack('H*', $r);
    if ($sum ne $test->{ sha256_hash}) {
      print "calculate_checksum($tmpfile, sha256) = $sum, wanted $test->{ sha256_hash }\n";
      $failures++;
      unlink $tmpfile;
      next;
    }

    if (!unlink $tmpfile) {
      print "test_util_calculate_checksum: Unable to unlink: $tmpfile: $!\n";
      $failures++;
      next;
    }
  }

  if ($failures == 0) {
    return 1;
  }

  print "$failures/" . (scalar(@tests)) . " test_util_calculate_checksum tests failed\n";
  return 0;
}

sub write_file {
  my ($filename, $contents) = @_;
  # Permit contents to be blank.
  if (!defined $filename || length $filename == 0 ||
    !defined $contents) {
    print "write_file: Invalid parameter\n";
    return 0;
  }

  my $fh;
  if (!open $fh, '>', $filename) {
    print "write_file: Unable to open file: $filename: $!\n";
    return 0;
  }

  if (!print { $fh } $contents) {
    print "write_file: Failure: Unable to write to file: $filename\n";
    return 0;
  }

  if (!close $fh) {
    print "write_file: Close failure: $filename\n";
    return 0;
  }

  return 1;
}

exit(&main ? 0 : 1);
