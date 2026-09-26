# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use File::Temp qw(tempdir);
use Mojolicious;
use Mojo::File qw(path);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Log;

our $VERSION = '0.001';

# Mojolicious logs to STDERR by default and Mojo::Server::daemonize reopens
# STDERR on /dev/null before Hypnotoad forks, so a logger left on STDERR writes
# nowhere. Every shipped service unit daemonizes, which meant a production
# deployment had no application log at all. See docs/QUALITY_PROGRAM.md 3.1.
my $directory = tempdir( CLEANUP => 1 );
my $log_file  = "$directory/gpforum.log";

my $configured = Mojolicious->new;
GPForum::Log->configure( $configured,
    GPForum::Config->new( log_level => 'info', log_path => $log_file ),
);
is( $configured->log->level, 'info',    'the configured level is applied' );
is( $configured->log->path,  $log_file, 'the configured path is applied' );
$configured->log->info('incident line');
ok( -s $log_file, 'a configured destination receives the line' );
like(
    path($log_file)->slurp,
    qr/incident [ ] line/msx,
    'the line survives where an operator can read it'
);

my $bare = Mojolicious->new;
GPForum::Log->configure( $bare, GPForum::Config->new( log_level => 'warn' ) );
is( $bare->log->level, 'warn', 'the level is applied without a path' );
is( $bare->log->path, undef,
    'no path leaves the logger on STDERR for a foreground supervisor' );

# Every shipped unit has to name a destination, or the deployment it describes
# silently discards its own log.
for my $unit ( sort glob 'deploy/systemd/*.service' ) {
    like(
        path($unit)->slurp,
        qr/^Environment=GPFORUM_LOG_PATH=\S+$/msx,
        "$unit configures a log destination"
    );
}
like( path('deploy/freebsd/gpforum')->slurp,
    qr/GPFORUM_LOG_PATH=/msx,
    'the FreeBSD rc script configures a log destination' );
for my $plist ( sort glob 'deploy/launchd/*.plist' ) {
    like( path($plist)->slurp,
        qr/GPFORUM_LOG_PATH/msx, "$plist configures a log destination" );
}

done_testing();
