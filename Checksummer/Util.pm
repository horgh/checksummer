#
# Generic utility functions.
#

package Checksummer::Util;

use Exporter qw/import/;
use Digest::MD5 qw//;
use Digest::SHA qw//;

our @EXPORT = qw/info error debug/;

# Boolean. Whether to show debug output.
my $DEBUG = 0;

# Build checksum for a given file.
#
# Parameters:
#
# $file, string. The path to the file.
#
# $hash_method, string. sha256 or md5. The hash function to use.
#
# Returns: A string, the checksum, or undef if failure.
sub calculate_checksum {
	my ($file, $hash_method) = @_;

	# Optimization: I am not checking parameters here any more.

	if ($hash_method eq 'sha256') {
		my $sha = Digest::SHA->new(256);

		# I used to use portable mode (m). Doesn't seem useful.

		# b is binary mode.
		$sha->addfile($file, 'b');

		# I used to use b64digest, and then hexdigest.

		# I am making an assumption that digest() is faster though, so I use that
		# now.
		return $sha->digest;
	}

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
	&debug('info', $msg);
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
}

sub set_debug {
	my ($v) = @_;
	$DEBUG = $v;
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
		&stderr("debug: No level specified.");
		return;
	}
	if (!defined $msg) {
		&stderr("debug: No message given.");
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
		&stderr($output);
	} else {
		&stdout($output);
	}
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
}

1;
