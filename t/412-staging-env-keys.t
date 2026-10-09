# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::Service::Operations::StagingHostVerify;

our $VERSION = '0.001';

# staging-host-verify reports which required keys an env file sets, never
# their values. A key counts when its value is not empty once one pair of
# surrounding quotes is taken off; spaces around the = are allowed, and a
# commented line, a name that is not a shell name or a value of only spaces
# sets nothing.
my $directory = tempdir( CLEANUP => 1 );
my $file      = path( $directory, 'gpforum.env' );
$file->spew(
    join "\n",
    q{  GPFORUM_SESSION_SECRET = "quoted secret"},
    q{GPFORUM_DATABASE_DSN='dbi:Pg:dbname=gpforum'},
    q{GPFORUM_DATABASE_USER=""},
    q{# GPFORUM_METRICS_TOKEN=commented},
    q{1GPFORUM_METRICS_TOKEN=not-a-name},
    q{GPFORUM_METRICS_TOKEN =   },
    q{}
);

my $env = GPForum::Service::Operations::StagingHostVerify->new->run(
    { env_file => $file->to_string } )->{env_file};
is_deeply(
    $env->{present_keys},
    [qw(GPFORUM_SESSION_SECRET GPFORUM_DATABASE_DSN)],
    'quoted values and spaces around = count'
);
is_deeply(
    $env->{missing_keys},
    [qw(GPFORUM_DATABASE_USER GPFORUM_METRICS_TOKEN)],
    q{an empty quoted value, a comment, a bad name and spaces do not}
);
is( $env->{status}, 'fail', 'so the phase fails' );

done_testing();

1;
