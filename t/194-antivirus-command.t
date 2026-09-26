# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';

use GPForum::Infrastructure::Antivirus::Command;

our $VERSION = '0.001';

const my $EXECUTABLE    => oct '755';
const my $PRIVATE       => oct '600';
const my $SHORT_TIMEOUT => 1;

# A scanner program that follows ClamAV's exit convention -- 0 clean, 1
# found, 2 error -- and writes down the path and mode of the file it was
# given, so the test can check the copy was private and was removed.
my $directory = tempdir( CLEANUP => 1 );
my $witness   = "$directory/witness";
my $program   = "$directory/fake-scanner";
_write( $program, <<"SCANNER" );
#!$EXECUTABLE_NAME
use strict;
use warnings;
my \$path = \$ARGV[-1];
open my \$witness, '>', '$witness' or exit 2;
printf {\$witness} "%s %o\\n", \$path, ( stat \$path )[2] & 07777;
close \$witness;
open my \$file, '<', \$path or exit 2;
local \$/ = undef;
my \$content = <\$file>;
if ( \$content =~ /HANG/ ) { sleep 5; exit 0 }
if ( \$content =~ /KILLED/ ) { kill 'KILL', \$\$ }
if ( \$content =~ /DETACH/ ) { close STDOUT; close STDERR; sleep 5; exit 0 }
if ( \$content =~ /WARNED/ ) {
    print STDERR "LibClamAV Warning: *** The virus database is older than 7 days! ***\\n";
    print "\$path: Test.Warned FOUND\\n";
    exit 1;
}
if ( \$content =~ /BROKEN/ ) { print "\$path: Can't read\\n"; exit 2 }
if ( \$content =~ /MALWARE/ ) { print "\$path: Test.Malware FOUND\\n"; exit 1 }
print "\$path: OK\\n";
exit 0;
SCANNER
chmod $EXECUTABLE, $program or croak "chmod $program: $ERRNO";

my $scanner = GPForum::Infrastructure::Antivirus::Command->new(
    command => [ $program, '--no-summary' ] );

ok( !$scanner->answers_immediately,
    'a process per file is left to the attachment worker' );
is_deeply(
    $scanner->scan('an ordinary file'),
    { status => 'clean', engine => 'fake-scanner' },
    'exit 0 is clean'
);
my ( $path, $mode ) = split q{ }, _slurp($witness);
is( oct $mode, $PRIVATE, 'the scanner was given a private copy' );
ok( !-e $path, 'which is removed once the scan is done' );

is_deeply(
    $scanner->scan('contains MALWARE'),
    {
        status    => 'infected',
        engine    => 'fake-scanner',
        signature => 'Test.Malware'
    },
    'exit 1 is infected, with the signature the scanner printed'
);

my $broken = $scanner->scan('BROKEN input');
is( $broken->{status}, 'error', 'exit 2 is an error, never clean' );
like( $broken->{error}, qr/exited [ ] 2/msx, 'with the exit status' );

my $impatient = GPForum::Infrastructure::Antivirus::Command->new(
    command         => [$program],
    timeout_seconds => $SHORT_TIMEOUT,
);
my $hung = $impatient->scan('please HANG');
is( $hung->{status}, 'error', 'a scanner that hangs is an error' );
like( $hung->{error}, qr/timed [ ] out/msx, 'reported as a timeout' );
( $path, $mode ) = split q{ }, _slurp($witness);
ok( !-e $path, 'and its copy is removed even so' );

# A scanner killed by a signal -- the OOM killer, or a crash on a crafted
# file -- exits with status byte 0. That must never read as clean.
my $killed = $scanner->scan('KILLED while scanning');
is( $killed->{status}, 'error', 'a scanner killed by a signal is an error' );
like( $killed->{error}, qr/signal [ ] 9/msx, 'naming the signal' );

my $detached = $impatient->scan('DETACH and keep running');
is( $detached->{status}, 'error',
    'the timeout also covers a scanner that closes its output and runs on' );

is( $scanner->scan('WARNED file')->{signature},
    'Test.Warned', 'warnings on stderr do not leak into the signature' );

my $missing = GPForum::Infrastructure::Antivirus::Command->new(
    command => ["$directory/not-installed"] );
is( $missing->scan('anything')->{status},
    'error', 'a scanner that is not installed is an error' );

is( $scanner->health(time)->{status}, 'ok',
    'an executable scanner is healthy' );
is( $missing->health(time)->{status},
    'degraded', 'a missing scanner degrades readiness' );
{
    local $ENV{PATH} = "$directory:$ENV{PATH}";
    is(
        GPForum::Infrastructure::Antivirus::Command->new(
            command => ['fake-scanner']
        )->health(time)->{status},
        'ok',
        'a scanner named without a path is found through PATH, as exec finds it'
    );
}

done_testing();

sub _write {
    my ( $file, $text ) = @_;

    open my $handle, '>', $file or croak "open $file: $ERRNO";
    print {$handle} $text or croak "write $file: $ERRNO";
    close $handle         or croak "close $file: $ERRNO";

    return;
}

sub _slurp {
    my ($file) = @_;

    open my $handle, '<', $file or croak "open $file: $ERRNO";
    local $INPUT_RECORD_SEPARATOR = undef;
    my $text = <$handle>;
    close $handle or croak "close $file: $ERRNO";
    chomp $text;

    return $text;
}

1;
