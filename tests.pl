#
# Some unit tests.
#

use strict;
use warnings;

use Checksummer qw//;
use Checksummer::Util qw//;
use File::Path qw//;
use File::Temp qw//;

sub main {
  Checksummer::Util::set_debug(1);

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

  if (!&test_read_config) {
    $failures++;
  }

  if (!&test_check_file) {
    $failures++;
  }

  if (!&test_is_file_excluded) {
    $failures++;
  }

  if (!&test_checksum_mismatch) {
    $failures++;
  }

  return $failures == 0;
}

sub test_read_config {
  my @tests = (
    # A config with a path that does not exist.
    {
      config => "
/dir1
",
      want_error => 1,
      paths      => [],
      exclusions => [],
    },

    # A config with paths that do exist and are absolute, and exclusions
    # that are absolute.
    {
      config => "
# Nice dir
/tmp

/home

!/home/horgh
!/home/tester
",
      want_error => 0,
      paths      => ['/tmp', '/home',],
      exclusions => ['/home/horgh', '/home/tester',],
    },

    # A config with paths that are not absolute.
    {
      config => "
# Nice dir
./tmp

/home

!/home/horgh
!/home/tester
",
      want_error => 1,
      paths      => [],
      exclusions => [],
    },

    # A config where paths are absolute, but exclusions are not.
    {
      config => "
# Nice dir
/tmp

/home

!./home/horgh
!./home/tester
",
      want_error => 1,
      paths      => [],
      exclusions => [],
    },

    # A config where one of the paths is a regular file.
    {
      config => "
/etc/passwd

/home

!/home/horgh
!/home/tester
",
      want_error => 1,
      paths      => [],
      exclusions => [],
    },

    # No paths at all.
    {
      config => "
!/home/horgh
!/home/tester
",
      want_error => 1,
      paths      => [],
      exclusions => [],
    },
  );

  my $tmpfile = File::Temp::tmpnam();

  my $failures = 0;

  TEST: foreach my $test (@tests) {
    if (!&write_file($tmpfile, $test->{ config })) {
      print "test_read_config: Unable to write file: $tmpfile\n";
      $failures++;
      next;
    }

    my $config = Checksummer::read_config($tmpfile);
    unlink $tmpfile;

    if ($test->{ want_error }) {
      if ($config) {
        print "read_config() succeeded, wanted error.\n";
        print "config = $test->{ config }\n";
        $failures++;
        next;
      }

      next;
    }

    if (!$config) {
      print "read_config() failed, wanted success\n";
      print "config = $test->{ config }\n";
      $failures++;
      next;
    }

    if (scalar @{ $config->{ paths } } != scalar @{ $test->{ paths } }) {
      print "read_config() yielded " . scalar(@{ $config->{ paths } })
        . " paths, wanted " . scalar(@{ $test->{ paths } }) . "\n";
      print "config = $test->{ config }\n";
      $failures++;
      next;
    }

    for (my $i = 0; $i < scalar @{ $test->{ paths } }; $i++) {
      my $wanted_path = $test->{ paths }[ $i ];
      my $got_path = $config->{ paths }[ $i ];

      if ($wanted_path ne $got_path) {
        print "read_config() path mismatch. path $i is $got_path, wanted $wanted_path\n";
        print "config = $test->{ config }\n";
        $failures++;
        next TEST;
      }
    }

    if (scalar @{ $config->{ exclusions } } != scalar @{ $test->{ exclusions } }) {
      print "read_config() yielded " . scalar(@{ $config->{ exclusions } })
        . " exclusions, wanted " . scalar(@{ $test->{ exclusions } }) . "\n";
      print "config = $test->{ config }\n";
      $failures++;
      next;
    }

    for (my $i = 0; $i < scalar @{ $test->{ exclusions } }; $i++) {
      my $wanted = $test->{ exclusions }[ $i ];
      my $got = $config->{ exclusions }[ $i ];

      if ($wanted ne $got) {
        print "read_config() exclusion mismatch. exclusion $i is $got, wanted $wanted\n";
        print "config = $test->{ config }\n";
        $failures++;
        next TEST;
      }
    }
  }

  if ($failures == 0) {
    return 1;
  }

  print "test_read_config: $failures/" . scalar(@tests) . " failed\n";
  return 0;
}

sub test_check_file {
  my $now = time;
  my $one_hour_ago = time - 60*60;
  my $one_week_ago = time - (7*24*60*60);

  my @tests = (
    # The file does not exist. No error as we check if the file is readable and
    # do not raise an error if it is not.
    {
      desc  => 'file does not exist',
      file  => '/test.txt',
      files => [
        {
          path   => '/test.txt',
          dir    => 0,
          exists => 0,
          mtime  => $one_hour_ago,
        },
      ],
      db_checksums => {},
      exclusions   => [],
      want_error   => 0,
      output       => [],
    },

    # Regular file. Checksums match.
    {
      desc  => 'checksums match',
      file  => '/test.txt',
      files => [
        {
          path    => '/test.txt',
          dir     => 0,
          exists  => 1,
          mtime   => $one_hour_ago,
          content => "123",
        },
      ],
      db_checksums => {
        # checksum of 123
        '/test.txt' => '202cb962ac59075b964b07152d234b70',
      },
      exclusions => [],
      want_error => 0,
      output     => [],
    },

    # Regular file. Checksum is not yet in the database.
    {
      desc  => 'checksum is not in database',
      file  => '/test.txt',
      files => [
        {
          path    => '/test.txt',
          dir     => 0,
          exists  => 1,
          mtime   => $one_hour_ago,
          content => "123",
        },
      ],
      db_checksums => {
      },
      exclusions => [],
      want_error => 0,
      output     => [
        {
          file     => '/test.txt',
          checksum => '202cb962ac59075b964b07152d234b70',
          ok       => 1,
        },
      ],
    },

    # Regular file. Checksum mismatch, but recently enough that it is okay.
    {
      desc  => 'checksum mismatch, but ok',
      file  => '/test.txt',
      files => [
        {
          path    => '/test.txt',
          dir     => 0,
          exists  => 1,
          mtime   => $one_hour_ago,
          content => "123",
        },
      ],
      db_checksums => {
        '/test.txt' => 'ff',
      },
      exclusions => [],
      want_error => 0,
      output     => [
        {
          file     => '/test.txt',
          checksum => '202cb962ac59075b964b07152d234b70',
          ok       => 1,
        },
      ],
    },

    # Regular file. Checksum mismatch, and and it is long enough ago that it is
    # a problem.
    {
      desc  => 'checksum mismatch, and not ok',
      file  => '/test.txt',
      files => [
        {
          path    => '/test.txt',
          dir     => 0,
          exists  => 1,
          mtime   => $one_week_ago,
          content => "123",
        },
      ],
      db_checksums => {
        '/test.txt' => 'ff',
      },
      exclusions => [],
      want_error => 0,
      output     => [
        {
          file     => '/test.txt',
          checksum => '202cb962ac59075b964b07152d234b70',
          ok       => 0,
        },
      ],
    },

    # Directory. All file checksums match.
    {
      desc  => 'directory, all checksums match',
      file  => '/testdir',
      files => [
        {
          path    => '/testdir',
          dir     => 1,
          exists  => 1,
        },
        {
          path    => '/testdir/test.txt',
          dir     => 0,
          exists  => 1,
          mtime   => $one_week_ago,
          content => "123",
        },
        {
          path    => '/testdir/test2.txt',
          dir     => 0,
          exists  => 1,
          mtime   => $one_week_ago,
          content => "123",
        },
      ],
      db_checksums => {
        '/testdir/test.txt'  => '202cb962ac59075b964b07152d234b70',
        '/testdir/test2.txt' => '202cb962ac59075b964b07152d234b70',
      },
      exclusions => [],
      want_error => 0,
      output     => [
      ],
    },

    # Directory. All file checksums match, one is not in the database.
    {
      desc  => 'directory, all checksums match, one not in database',
      file  => '/testdir',
      files => [
        {
          path    => '/testdir',
          dir     => 1,
          exists  => 1,
        },
        {
          path    => '/testdir/test.txt',
          dir     => 0,
          exists  => 1,
          mtime   => $one_week_ago,
          content => "123",
        },
        {
          path    => '/testdir/test2.txt',
          dir     => 0,
          exists  => 1,
          mtime   => $one_week_ago,
          content => "123",
        },
        {
          path    => '/testdir/test3.txt',
          dir     => 0,
          exists  => 1,
          mtime   => $one_week_ago,
          content => "123",
        },
      ],
      db_checksums => {
        '/testdir/test.txt'  => '202cb962ac59075b964b07152d234b70',
        '/testdir/test2.txt' => '202cb962ac59075b964b07152d234b70',
      },
      exclusions => [],
      want_error => 0,
      output     => [
        {
          file     => '/testdir/test3.txt',
          checksum => '202cb962ac59075b964b07152d234b70',
          ok       => 1,
        },
      ],
    },

    # Directory. All file checksums match except one, but recently enough that
    # it is okay.
    {
      desc  => 'directory, checksums match except one different but ok',
      file  => '/testdir',
      files => [
        {
          path   => '/testdir',
          dir    => 1,
          exists => 1,
        },
        {
          path    => '/testdir/test.txt',
          dir     => 0,
          exists  => 1,
          mtime   => $one_week_ago,
          content => "123",
        },
        {
          path    => '/testdir/test2.txt',
          dir     => 0,
          exists  => 1,
          mtime   => $one_hour_ago,
          content => "123",
        },
      ],
      db_checksums => {
        '/testdir/test.txt'  => '202cb962ac59075b964b07152d234b70',
        '/testdir/test2.txt' => 'ff',
      },
      exclusions => [],
      want_error => 0,
      output     => [
        {
          file     => '/testdir/test2.txt',
          checksum => '202cb962ac59075b964b07152d234b70',
          ok       => 1,
        },
      ],
    },

    # Directory. All file checksums match except one, and it is long enough ago
    # that it is a problem.
    {
      desc  => 'directory, one checksum different, and it is a problem',
      file  => '/testdir',
      files => [
        {
          path   => '/testdir',
          dir    => 1,
          exists => 1,
        },
        {
          path    => '/testdir/test.txt',
          dir     => 0,
          exists  => 1,
          mtime   => $one_week_ago,
          content => "123",
        },
        {
          path    => '/testdir/test2.txt',
          dir     => 0,
          exists  => 1,
          mtime   => $one_week_ago,
          content => "123",
        },
      ],
      db_checksums => {
        '/testdir/test.txt'  => '202cb962ac59075b964b07152d234b70',
        '/testdir/test2.txt' => 'ff',
      },
      exclusions => [],
      want_error => 0,
      output     => [
        {
          file     => '/testdir/test2.txt',
          checksum => '202cb962ac59075b964b07152d234b70',
          ok       => 0,
        },
      ],
    },

    # Symlink. It should be skipped.
    {
      desc  => 'symlink',
      file  => '/testlink',
      files => [
        {
          path    => '/testlink',
          dir     => 0,
          symlink => 1,
          exists  => 1,
        },
      ],
      db_checksums => {
      },
      exclusions => [],
      want_error => 0,
      output     => [
      ],
    },

    # Checksum mismatch, long enough ago that it is a problem. But the file is
    # excluded.
    {
      desc  => 'directory, one checksum different, and it is a problem',
      file  => '/testdir',
      files => [
        {
          path   => '/testdir',
          dir    => 1,
          exists => 1,
        },
        {
          path    => '/testdir/test.txt',
          dir     => 0,
          exists  => 1,
          mtime   => $one_week_ago,
          content => "123",
        },
        {
          path    => '/testdir/test2.txt',
          dir     => 0,
          exists  => 1,
          mtime   => $one_week_ago,
          content => "123",
        },
      ],
      db_checksums => {
        '/testdir/test.txt'  => '202cb962ac59075b964b07152d234b70',
        '/testdir/test2.txt' => 'ff',
      },
      exclusions => ['/testdir/test2.txt'],
      want_error => 0,
      output     => [
      ],
    },
  );

  my $working_dir = File::Temp::tmpnam();
  my $hash_method = 'md5';

  my $failures = 0;

  TEST: foreach my $test (@tests) {
    print "test_check_file: Running test $test->{ desc }...\n";

    if (!mkdir($working_dir)) {
      print "test_check_file: unable to create working directory: $working_dir: $!\n";
      $failures++;
      next;
    }

    # Create the files as described by the test.

    foreach my $file (@{ $test->{ files } }) {
      if (!$file->{ exists }) {
        next;
      }

      my $path = $working_dir . $file->{ path };

      if ($file->{ symlink }) {
        if (!symlink('/tmp', $path)) {
          print "test_check_file: Unable to symlink: $path\n";
          $failures++;
          File::Path::remove_tree($working_dir);
          next TEST;
        }

        next;
      }

      if ($file->{ dir }) {
        if (!mkdir($path)) {
          print "test_check_file: Unable to mkdir $path\n";
          $failures++;
          File::Path::remove_tree($working_dir);
          next TEST;
        }

        next;
      }

      # Regular file.

      if (!&write_file($path, $file->{ content })) {
        print "test_check_file: unable to write file: $path\n";
        $failures++;
        File::Path::remove_tree($working_dir);
        next TEST;
      }

      if (utime($file->{ mtime }, $file->{ mtime }, $path) != 1) {
        print "test_check_file: unable to set mtime: $path\n";
        $failures++;
        File::Path::remove_tree($working_dir);
        next TEST;
      }
    }

    # We need to prefix the checksums from the database with the working
    # directory. We also must convert the checksum from hex to binary.
    my %db_checksums;
    foreach my $file (keys %{ $test->{ db_checksums } }) {
      my $path = $working_dir . $file;
      my $checksum = pack('H*', $test->{ db_checksums }{ $file });
      $db_checksums{ $path } = $checksum;
    }

    # Prefix exclusions with the working dir path.
    my @exclusions;
    foreach my $exclusion (@{ $test->{ exclusions } }) {
      my $path = $working_dir . $exclusion;
      push @exclusions, $path;
    }

    # 'file' is the file we start checking from. It might be a regular file or
    # it might be a directory. In either case, we have to prefix what the test
    # said with the working directory.
    my $start_file = $working_dir . $test->{ file };

    my $r = Checksummer::check_file($start_file, $hash_method, \@exclusions,
      \%db_checksums);
    File::Path::remove_tree($working_dir);

    if ($test->{ want_error }) {
      if (defined $r) {
        print "test_check_file: wanted error, but received result\n";
        $failures++;
        next;
      }

      next;
    }

    if (!defined $r) {
      print "test_check_file: returned error\n";
      $failures++;
      next;
    }

    if (@{ $r } != @{ $test->{ output } }) {
      print "test_check_file: got " . scalar(@$r) . " checksums, wanted " . scalar(@{ $test->{ output }}) . "\n";
      $failures++;
      next;
    }

    # Compare the checksums we received (remember, only those files changed or
    # are new are returned) with what we expected to be returned.

    for (my $i = 0; $i < @{ $r }; $i++) {
      my $got = $r->[ $i ];
      my $wanted = $test->{ output }[ $i ];

      my $wanted_file = $working_dir . $wanted->{ file };
      if ($got->{ file } ne $wanted_file) {
        print "test_check_file: file $i file is $got->{ file }, wanted $wanted_file\n";
        $failures++;
        next TEST;
      }

      my $got_sum = unpack('H*', $got->{ checksum });
      if ($got_sum ne $wanted->{ checksum }) {
        print "test_check_file: file $i checksum is $got_sum, wanted $wanted->{ checksum }\n";
        $failures++;
        next TEST;
      }

      if ($got->{ ok } != $wanted->{ ok }) {
        print "test_check_file: file $i ok is $got->{ ok }, wanted $wanted->{ ok }\n";
        $failures++;
        next TEST;
      }
    }
  }

  if ($failures == 0) {
    return 1;
  }

  print "$failures/" . (scalar(@tests)) . " test_check_file tests failed\n";
  return 0;
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
        unlink $tmpfile;
        next;
      }
    }

    my $r = Checksummer::checksum_mismatch($tmpfile, $new_checksum,
      $old_checksum);
    unlink $tmpfile if $test->{ file_exists };

    if ($r != $test->{ output }) {
      print "checksum_mismatch($tmpfile, ...) = $r, wanted $test->{ output }\n";
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

    unlink $tmpfile;

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
