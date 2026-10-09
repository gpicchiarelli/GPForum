# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use English          qw(-no_match_vars);
use File::Temp       qw(tempdir);
use IO::Socket::INET ();
use Mojo::File       qw(path);
use Test::More;

use lib 'lib';

use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::HttpProbe;

our $VERSION = '0.001';

# The one GET gpforum doctor and gpforum status make. An https address --
# the public one -- goes through curl on a host without IO::Socket::SSL (an
# install from before the lock had it), with the token on curl's standard input rather than its
# command line, where ps shows it to every user; curl's failures come back
# by kind, so the sentence an operator reads can say "connection refused".
# curl here is a script that does what curl would.

const my $TOKEN      => 'a-metrics-token';
const my $EXECUTABLE => oct '755';
const my $HTTP_OK    => 200;
const my $READ_SIZE  => 4096;
const my %CURL_EXIT => (
    unresolved => 6,
    refused    => 7,
    timeout    => 28,
    tls        => 60,
    other      => 22,
);

my $directory = tempdir( CLEANUP => 1 );
my $log       = path( $directory, 'curl.log' );
my $curl      = path( $directory, 'curl' );
$curl->spew(<<"SH");
#!/bin/sh
# Writes its arguments and its standard input to the log, then answers as
# CURL_EXIT asks.
printf '%s\\n' "\$*" > '$log'
cat >> '$log'
if [ -n "\$CURL_EXIT" ]; then
    echo "curl: (\$CURL_EXIT) it failed" >&2
    exit "\$CURL_EXIT"
fi
while [ \$# -gt 0 ]; do
    if [ "\$1" = --output ]; then printf '{"status":"ok"}' > "\$2"; fi
    shift
done
printf 200
SH
$curl->chmod($EXECUTABLE);

my $probe =
  GPForum::Service::Operations::HttpProbe->new( curl => "$curl", can_tls => 0 );

subtest 'an https address through curl' => sub {
    local $ENV{CURL_EXIT} = q{};
    my $answer = $probe->get(
        'https://forum.gpforum.net/health/ready',
        { 'X-GPForum-Metrics-Token' => $TOKEN }
    );
    is( $answer->{client}, 'curl',            'curl asked' );
    is( $answer->{code},   $HTTP_OK,          'the status' );
    is( $answer->{body},   '{"status":"ok"}', 'and the body' );

    my ( $arguments, @input ) = split /\n/msx, $log->slurp;
    unlike( $arguments, qr/\Q$TOKEN\E/msx,
        'the token is not on its command line' );
    like(
        $arguments,
        qr/--config [ ] -/msx,
        'which reads the rest from its input'
    );
    is_deeply(
        \@input,
        [
            qq{header = "X-GPForum-Metrics-Token: $TOKEN"},
            q{url = "https://forum.gpforum.net/health/ready"},
        ],
        'where the header and the address are'
    );
};

subtest q{curl's failures, by kind} => sub {
    for my $kind ( sort keys %CURL_EXIT ) {
        my $exit = $CURL_EXIT{$kind};
        local $ENV{CURL_EXIT} = $exit;
        my $answer = $probe->get('https://forum.gpforum.net/health/live');
        is( $answer->{kind}, $kind, "exit $exit is $kind" );
        is( $answer->{error}, 'it failed',
            'with what curl said, its prefix gone' );
    }
};

subtest 'no curl is said, not guessed' => sub {
    my $answer = GPForum::Service::Operations::HttpProbe->new(
        curl    => undef,
        can_tls => 0
    )->get('https://forum.gpforum.net/health/live');
    is( $answer->{kind}, 'unsupported', 'unsupported, with nothing asked' );
};

subtest 'plain HTTP through Mojo::UserAgent' => sub {
    my $listener = IO::Socket::INET->new(
        Listen    => 1,
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
    ) or BAIL_OUT("cannot listen: $OS_ERROR");
    my $port = $listener->sockport;
    close $listener or BAIL_OUT("cannot close: $OS_ERROR");

    my $answer = GPForum::Service::Operations::HttpProbe->new( timeout => 2 )
      ->get("http://127.0.0.1:$port/health/live");
    is( $answer->{client}, 'mojo',    'Mojo asked' );
    is( $answer->{kind},   'refused', 'a closed port is refused' );
};

subtest 'a port that answers plain HTTP is a handshake, through Mojo too' =>
  sub {
    if ( !Mojo::IOLoop::TLS->can_tls ) {
        plan skip_all => 'without IO::Socket::SSL, curl asks https';
    }
    my $listener = IO::Socket::INET->new(
        Listen    => 1,
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        ReuseAddr => 1,
    ) or BAIL_OUT("cannot listen: $OS_ERROR");
    my $port = $listener->sockport;
    my $pid  = fork // BAIL_OUT("cannot fork: $OS_ERROR");
    if ( !$pid ) {
        _answer_plain_http($listener);
    }

    my $answer = GPForum::Service::Operations::HttpProbe->new( timeout => 2 )
      ->get("https://127.0.0.1:$port/health/live");
    kill 'KILL', $pid;
    waitpid $pid, 0;
    close $listener or BAIL_OUT("cannot close: $OS_ERROR");
    is( $answer->{client}, 'mojo',      'Mojo asked' );
    is( $answer->{kind},   'handshake', 'a handshake, as curl says it' );
  };

subtest 'why there was no answer, as an operator reads it' => sub {
    my $english = GPForum::Service::I18N::CliCatalog->new( language => 'en' );
    my $italian = GPForum::Service::I18N::CliCatalog->new( language => 'it' );
    is( $probe->reason( { kind => 'refused' }, $english ),
        'connection refused', 'refused' );
    is(
        $probe->reason( { kind => 'timeout' }, $english ),
        'no answer within 5 s',
        'a timeout, with the wait'
    );
    is(
        $probe->reason( { kind => 'refused' }, $italian ),
        'connessione rifiutata',
        'in Italian'
    );
    is(
        $probe->reason(
            { kind => 'other', error => "it broke\nbadly" }, $english
        ),
        'it broke',
        q{anything else, the client's first line}
    );
};

done_testing();

# A listener that answers every connection with plain HTTP, as nginx's port
# 443 does when its server block has no ssl, until it is killed.
sub _answer_plain_http ($listener) {
    while ( my $client = $listener->accept ) {
        sysread $client, my $request, $READ_SIZE;
        print {$client} "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n"
          . "Connection: close\r\n\r\n"
          or last;
        close $client or last;
    }
    exit 0;
}

1;
