#
# Some unit tests.
#

use strict;
use warnings;

use Checksummer::Util qw//;
use File::Temp qw//;

sub main {
  my $failures = 0;

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

# Checksummer::Util tests
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
      next;
    }

    $r = Checksummer::Util::calculate_checksum($tmpfile, 'md5');
    if (!defined $r) {
      print "calculate_checksum($tmpfile, md5): Unable to calculate checksum\n";
      $failures++;
      next;
    }

    my $sum = unpack('H*', $r);
    if ($sum ne $test->{ md5_hash}) {
      print "calculate_checksum($tmpfile, md5) = $sum, wanted $test->{ md5_hash }\n";
      $failures++;
      next;
    }

    $r = Checksummer::Util::calculate_checksum($tmpfile, 'sha256');
    if (!defined $r) {
      print "calculate_checksum($tmpfile, sha256): Unable to calculate checksum\n";
      $failures++;
      next;
    }

    $sum = unpack('H*', $r);
    if ($sum ne $test->{ sha256_hash}) {
      print "calculate_checksum($tmpfile, sha256) = $sum, wanted $test->{ sha256_hash }\n";
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
