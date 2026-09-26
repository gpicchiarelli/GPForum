# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Digest::SHA qw(sha256_hex);
use English     qw(-no_match_vars);
use File::Temp  qw(tempdir);
use IO::Socket::UNIX;
use POSIX  qw(_exit);
use Socket qw(SOCK_STREAM);
use Test::More;
use Time::HiRes qw(sleep);
use Time::Piece ();

use lib 'lib';

use GPForum::Infrastructure::Antivirus::Clamd;

our $VERSION = '0.001';

const my $STREAM_LIMIT     => 1_000_000;
const my $REQUEST_BUDGET   => 3;
const my $BYTE_VALUES      => 256;
const my $LENGTH_BYTES     => 4;
const my $FRAMED_BYTES     => 300_000;
const my $OVERSIZED_BYTES  => 1_500_000;
const my $HANG_SECONDS     => 3;
const my $SHORT_TIMEOUT    => 1;
const my $STARTUP_ATTEMPTS => 50;
const my $STARTUP_PAUSE    => 0.1;
const my $STALE_DAYS       => 10;
const my $DAY_SECONDS      => 86_400;
const my $PUBLISHED_FORMAT => '%a %b %d %H:%M:%S %Y';
const my $STALLED_BYTES    => 2_000_000;
const my $STALL_SECONDS    => 30;
const my $PROMPT_SECONDS   => 5;

# A clamd that speaks the real protocol on a real UNIX socket: commands end in
# NUL, INSTREAM is 4-byte big-endian lengths with a zero terminator, and it
# answers and hangs up when the stream passes its limit, as clamd does. It
# records the SHA-256 of what it reassembled, so the test can prove the chunk
# framing delivered the bytes intact.
my $directory = tempdir( CLEANUP => 1 );
my $socket    = "$directory/clamd.sock";
my $published = "$directory/published";
_write( $published, _date(time) );
my $server = _start_server();

my $clamd = GPForum::Infrastructure::Antivirus::Clamd->new(
    socket_path     => $socket,
    timeout_seconds => 5,
);

ok( $clamd->answers_immediately, 'clamd is fast enough for the request' );
is( $clamd->within_request->timeout_seconds,
    $REQUEST_BUDGET,
    'inside a request it waits three seconds, within Hypnotoad\'s heartbeat' );
is( $clamd->within_request->socket_path, $socket, 'on the same socket' );
ok( $clamd->ping, 'PING is answered with PONG' );
is( $clamd->version->{engine},   'ClamAV 1.4.1', 'VERSION names the engine' );
is( $clamd->version->{database}, '27400',        'and the signature database' );

is_deeply(
    $clamd->scan('an ordinary text file'),
    { status => 'clean', engine => 'ClamAV 1.4.1/27400' },
    'clean content is clean, with the engine that decided'
);

my $binary = join q{}, map { chr $_ % $BYTE_VALUES } 0 .. $FRAMED_BYTES - 1;
is( $clamd->scan($binary)->{status},
    'clean', 'a multi-chunk binary stream is scanned' );
is( _slurp("$directory/last-sha256"),
    sha256_hex($binary), 'clamd reassembled exactly the bytes that were sent' );

is_deeply(
    $clamd->scan('contains MALWARE here'),
    {
        status    => 'infected',
        signature => 'Test.Malware',
        engine    => 'ClamAV 1.4.1/27400'
    },
    'a detection is infected, with the signature name'
);

# clamd hangs up mid-stream; without SIGPIPE ignored this would kill the test.
my $oversized = $clamd->scan( 'x' x $OVERSIZED_BYTES );
is( $oversized->{status}, 'error', 'a stream past the limit is an error' );
like(
    $oversized->{error},
    qr/size [ ] limit/msx,
    'with clamd\'s own reason, not a broken pipe'
);

my $impatient = GPForum::Infrastructure::Antivirus::Clamd->new(
    socket_path     => $socket,
    timeout_seconds => $SHORT_TIMEOUT,
);
my $hung = $impatient->scan('please HANG');
is( $hung->{status}, 'error', 'a clamd that does not answer is an error' );
like( $hung->{error}, qr/did [ ] not [ ] answer/msx, 'within the timeout' );

# A clamd that accepts, reads a little and then stops reading, holding the
# connection open. On systems whose UNIX socket buffer is smaller than a chunk
# a blocking write would wait for it forever; the deadline must end it.
my $staller       = _start_staller("$directory/stall.sock");
my $stalled_clamd = GPForum::Infrastructure::Antivirus::Clamd->new(
    socket_path     => "$directory/stall.sock",
    timeout_seconds => $SHORT_TIMEOUT,
);
my $started = time;
my $stalled = $stalled_clamd->scan( 'x' x $STALLED_BYTES );
is( $stalled->{status}, 'error', 'a clamd that stops reading is an error' );
cmp_ok( time - $started,
    q{<}, $PROMPT_SECONDS,
    'reached within the timeout, not after clamd resumes' );
kill 'KILL', $staller;
waitpid $staller, 0;

my $absent = GPForum::Infrastructure::Antivirus::Clamd->new(
    socket_path => "$directory/missing.sock" );
my $refused = $absent->scan('anything');
is( $refused->{status}, 'error', 'a missing socket is an error, never clean' );
like( $refused->{error}, qr/cannot [ ] connect/msx, 'naming the socket' );

like(
    $clamd->scan(
        "caf\N{LATIN SMALL LETTER E WITH ACUTE} \N{WHITE SMILING FACE}")
      ->{error},
    qr/must [ ] be [ ] bytes/msx,
    'characters are refused; clamd scans bytes'
);

is( $clamd->health(time)->{status}, 'ok', 'fresh signatures are healthy' );
_write( $published, _date( time - $STALE_DAYS * $DAY_SECONDS ) );
my $stale = $clamd->health(time);
is( $stale->{status}, 'degraded', 'signatures ten days old degrade' );
like( $stale->{error}, qr/freshclam/msx, 'and point at freshclam' );
is( $absent->health(time)->{status},
    'degraded', 'an unreachable clamd degrades readiness, never fails it' );

kill 'TERM', $server;
waitpid $server, 0;

done_testing();

sub _start_server {
    my $pid = fork;
    croak "fork: $ERRNO" if !defined $pid;
    if ( !$pid ) {
        _serve();
        _exit(0);
    }
    for ( 1 .. $STARTUP_ATTEMPTS ) {
        return $pid if -S $socket;
        sleep $STARTUP_PAUSE;
    }
    croak 'the fake clamd did not start';
}

sub _start_staller {
    my ($path) = @_;

    my $pid = fork;
    croak "fork: $ERRNO" if !defined $pid;
    if ( !$pid ) {
        my $listener = IO::Socket::UNIX->new(
            Type   => SOCK_STREAM,
            Local  => $path,
            Listen => 1,
        ) or croak "listen $path: $ERRNO";
        my $client = $listener->accept;
        _read_exact( $client, length "zINSTREAM\0" );
        sleep $STALL_SECONDS;
        _exit(0);
    }
    for ( 1 .. $STARTUP_ATTEMPTS ) {
        return $pid if -S $path;
        sleep $STARTUP_PAUSE;
    }
    croak 'the stalling clamd did not start';
}

sub _serve {

    # As clamd does: a client that gave up must not take the server down.
    local $SIG{PIPE} = 'IGNORE';
    my $listener = IO::Socket::UNIX->new(
        Type   => SOCK_STREAM,
        Local  => $socket,
        Listen => 5,
    ) or croak "listen $socket: $ERRNO";
    while ( my $client = $listener->accept ) {
        _answer($client);
        close $client or croak "close client: $ERRNO";
    }

    return;
}

sub _answer {
    my ($client) = @_;

    my $command = _read_until_nul($client);
    return _say( $client, 'PONG' ) if $command eq 'zPING';
    return _say( $client, 'ClamAV 1.4.1/27400/' . _slurp($published) )
      if $command eq 'zVERSION';
    return _say( $client, 'UNKNOWN COMMAND' ) if $command ne 'zINSTREAM';

    my $content = q{};
    while (1) {
        my $length = unpack 'N', _read_exact( $client, $LENGTH_BYTES );
        last if !$length;
        if ( length($content) + $length > $STREAM_LIMIT ) {
            return _say( $client, 'INSTREAM size limit exceeded. ERROR' );
        }
        $content .= _read_exact( $client, $length );
    }
    _write( "$directory/last-sha256", sha256_hex($content) );
    if ( $content =~ /HANG/msx ) {
        sleep $HANG_SECONDS;
    }

    return _say( $client,
        $content =~ /MALWARE/msx
        ? 'stream: Test.Malware FOUND'
        : 'stream: OK' );
}

sub _read_until_nul {
    my ($client) = @_;

    my $text = q{};
    while ( sysread $client, my $byte, 1 ) {
        last if $byte eq "\0";
        $text .= $byte;
    }

    return $text;
}

sub _read_exact {
    my ( $client, $wanted ) = @_;

    my $bytes = q{};
    while ( length $bytes < $wanted ) {
        my $read = sysread $client, my $buffer, $wanted - length $bytes;
        last if !$read;
        $bytes .= $buffer;
    }

    return $bytes;
}

sub _say {
    my ( $client, $text ) = @_;

    syswrite $client, "$text\0";

    return;
}

sub _date {
    my ($epoch) = @_;

    # As clamd writes it: ctime, in the host's local time.
    return Time::Piece::localtime($epoch)->strftime($PUBLISHED_FORMAT);
}

sub _write {
    my ( $path, $text ) = @_;

    open my $handle, '>', $path or croak "open $path: $ERRNO";
    print {$handle} $text or croak "write $path: $ERRNO";
    close $handle         or croak "close $path: $ERRNO";

    return;
}

sub _slurp {
    my ($path) = @_;

    open my $handle, '<', $path or croak "open $path: $ERRNO";
    local $INPUT_RECORD_SEPARATOR = undef;
    my $text = <$handle>;
    close $handle or croak "close $path: $ERRNO";

    return $text;
}

1;
