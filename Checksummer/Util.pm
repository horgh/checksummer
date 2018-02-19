# Generic utility functions.

package Checksummer::Util;

use strict;
use warnings;

use Exporter qw/import/;
use Digest::MD5 qw//;
use File::stat qw//;

our @EXPORT = qw/info error debug/;

# Boolean. Whether to show debug output.
my $DEBUG = 0;

# Build checksum for a given file.
#
# Parameters:
#
# $file, string. The path to the file.
#
# Returns: A string, the checksum, or undef if failure.
sub calculate_checksum {
	my ($file) = @_;

	# Optimization: I am not checking parameters here any more.

	my $md5 = Digest::MD5->new;

	my $fh;
	if (!open $fh, '<', $file) {
		error("Unable to open file: $file: $!");
		return undef;
	}

	if (!binmode $fh) {
		error("Unable to set binmode: $file: $!");
		close $fh;
		return undef;
	}

	# addfile() croaks on failure.
	$md5->addfile($fh);

	if (!close $fh) {
		error("Unable to close: $file: $!");
		return undef;
	}

	return $md5->digest;
}

sub mtime {
	my ($path) = @_;
	if (!defined $path || length $path == 0) {
		error("mtime: Invalid parameter");
		return undef;
	}

	my $st = File::stat::stat($path);
	if (!$st) {
		error("mtime: stat failure: $path: $!");
		return undef;
	}

	return $st->mtime;
}

# Output a message at info level.
#
# Parameters:
#
# $msg, string. The message to write.
#
# Returns: None
sub info {
	my ($msg) = @_;
	if (!defined $msg) {
		return;
	}
	debug('info', $msg);
	return;
}

# Output a message at error level.
#
# Parameters:
#
# $msg, string. The message to write
#
# Returns: None
sub error {
	my ($msg) = @_;
	debug('error', $msg);
	return;
}

sub set_debug {
	my ($v) = @_;
	$DEBUG = $v;
	return;
}

# Parameters:
#
# $level, string. debug, info, or error. The log level.
#
# $msg, string. The message to write
#
# Returns: None
sub debug {
	my ($level, $msg) = @_;
	if (!defined $level) {
		stderr("debug: No level specified.");
		return;
	}
	if (!defined $msg) {
		stderr("debug: No message given.");
		return;
	}

	if (!$DEBUG && $level eq 'debug') {
		return;
	}

	chomp $msg;
	my $caller = (caller(1))[3];
	if ($caller =~ 'info' || $caller =~ 'error') {
		$caller = (caller(2))[3];
	}

	my $output;
	if ($DEBUG) {
		$output = "$caller: $msg";
	} else {
		$output = "$msg";
	}

	if ($level eq 'error') {
		stderr($output);
	} else {
		stdout($output);
	}
	return;
}

# Parameters:
#
# $msg, a string, the message to write.
#
# Returns: None
sub stdout {
	my ($msg) = @_;
	if (!defined($msg)) {
		print { \*STDOUT } "\n";
		return;
	}

	chomp $msg;
	print { \*STDOUT } "$msg\n";
	return;
}

# Parameters:
#
# $msg, a string, the message to write.
#
# Returns: None
sub stderr {
	my ($msg) = @_;
	if (!defined($msg)) {
		print { \*STDERR } "\n";
		return;
	}

	chomp $msg;
	print { \*STDERR } "$msg\n";
	return;
}

1;
