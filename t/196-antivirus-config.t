# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Config;
use GPForum::Infrastructure::Antivirus;
use GPForum::OS;

our $VERSION = '0.001';

const my $CLAMD_TIMEOUT   => 30;
const my $COMMAND_TIMEOUT => 120;

# ADR 0108: GPForum assumes the free antivirus the operating system's package
# manager installs, and finds clamd where that package puts its socket.
my %STAGING = (
    GPFORUM_ENV            => 'staging',
    GPFORUM_SESSION_SECRET => 'rotated-staging-secret',
    GPFORUM_METRICS_TOKEN  => 'metrics-token',
    GPFORUM_GLIFISTORE_URL => '127.0.0.1:9900',
);

is(
    GPForum::Config->from_environment( {} )->antivirus,
    'none',
    'development does not assume an antivirus is installed'
);
is(
    GPForum::Config->from_environment( {%STAGING} )->antivirus,
    'clamd',
    'staging and production scan with the system clamd by default'
);
is(
    GPForum::Config->from_environment(
        { %STAGING, GPFORUM_ANTIVIRUS => 'none' }
    )->antivirus,
    'none',
    'and the operator can turn it off, explicitly'
);
is_deeply(
    GPForum::Config->from_environment(
        {
            GPFORUM_ANTIVIRUS         => 'command',
            GPFORUM_ANTIVIRUS_COMMAND => '/usr/bin/clamdscan  --fdpass'
        }
    )->antivirus_command,
    [ '/usr/bin/clamdscan', '--fdpass' ],
    'a command is split into arguments, never given to a shell'
);
is(
    GPForum::Config->from_environment( { GPFORUM_ANTIVIRUS => 'clamd' } )
      ->antivirus_timeout_seconds,
    $CLAMD_TIMEOUT,
    'clamd scans within 30 seconds by default'
);
is(
    GPForum::Config->from_environment(
        {
            GPFORUM_ANTIVIRUS         => 'command',
            GPFORUM_ANTIVIRUS_COMMAND => '/usr/bin/clamscan'
        }
    )->antivirus_timeout_seconds,
    $COMMAND_TIMEOUT,
    'a scanner command, which loads its signatures per file, gets 120'
);
throws_ok {
    GPForum::Config->from_environment( { GPFORUM_ANTIVIRUS => 'sophos' } );
}
qr/antivirus [ ] must [ ] be/msx, 'an unknown engine is refused';
throws_ok {
    GPForum::Config->from_environment( { GPFORUM_ANTIVIRUS => 'command' } );
}
qr/requires [ ] GPFORUM_ANTIVIRUS_COMMAND/msx,
  'a command engine without a command is refused';

# The packaged sockets, as each package's own configuration declares them.
my %PACKAGED = (
    linux   => '/var/run/clamav/clamd.ctl',
    freebsd => '/var/run/clamav/clamd.sock',
    darwin  => '/opt/local/var/run/clamav/clamd.socket',
);
for my $name ( sort keys %PACKAGED ) {
    my $os = GPForum::OS->from_name($name);
    is( $os->antivirus_packaging->{socket},
        $PACKAGED{$name}, "$name: the packaged clamd socket" );
    like( $os->antivirus_packaging->{install},
        qr/clamav/msx, "$name: and how the operator installs it" );
}

my $clamd = GPForum::Config->new( antivirus => 'clamd' );
is(
    GPForum::Infrastructure::Antivirus->from_config( $clamd,
        GPForum::OS->from_name('freebsd') )->socket_path,
    '/var/run/clamav/clamd.sock',
    'clamd is found where the operating system package put it'
);
is(
    GPForum::Infrastructure::Antivirus->from_config(
        GPForum::Config->new(
            antivirus        => 'clamd',
            antivirus_socket => '/srv/clamd.sock'
        ),
        GPForum::OS->from_name('freebsd')
    )->socket_path,
    '/srv/clamd.sock',
    'unless the operator names another socket'
);
my $unplaced = GPForum::Infrastructure::Antivirus->from_config( $clamd,
    GPForum::OS->from_name('unknown') );
like(
    $unplaced->scan('anything')->{error},
    qr/set [ ] GPFORUM_ANTIVIRUS_SOCKET/msx,
    'an operating system with no packaged default asks for the socket'
);
is( $unplaced->health(time)->{status},
    'degraded', 'without taking the node or the outbox down' );
ok(
    !defined GPForum::Infrastructure::Antivirus->from_config(
        GPForum::Config->new( antivirus => 'none' )
    ),
    'scanning off builds no scanner'
);
isa_ok(
    GPForum::Infrastructure::Antivirus->from_config(
        GPForum::Config->new(
            antivirus         => 'command',
            antivirus_command => ['/usr/bin/clamscan']
        )
    ),
    'GPForum::Infrastructure::Antivirus::Command',
    'a command engine'
);

done_testing();

1;
