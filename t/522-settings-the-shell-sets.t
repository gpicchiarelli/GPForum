# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Support::Words;
use GPForum::Config;

our $VERSION = '0.001';

# The process environment comes before the environment file (ADR 0120), so a
# setting the shell exported stays as the shell set it, whatever the file
# says. The settings report told the operator to set it in the file: with
# GPFORUM_ENV=prod exported and production in the file, they were sent to a
# file that was already right.

local %ENV = %ENV;
delete @ENV{ grep { /\A GPFORUM_/msx } keys %ENV };
local $ENV{LC_ALL} = 'en_US.UTF-8';

my $file = path( tempdir( CLEANUP => 1 ), 'gpforum.env' );
$file->spew("GPFORUM_ENV=production\nGPFORUM_WEB_PROCESSES=601\n");
local $ENV{GPFORUM_ENV} = 'prod';
GPForum::Command::Support::ServiceEnvironment->new( file => "$file" )->load;

my $report = _report();

my $shell = q{The shell's environment sets GPFORUM_ENV, which comes before};
ok( index( $report, "\n$shell $file:" ) > 0,
    'a variable the shell set is to be corrected in the shell' );
like(
    $report,
    qr/^Set [ ] these [ ] in [ ] \Q$file\E, [ ] then [ ] try [ ] again[.]$/msx,
    'one the file set, in the file'
);
unlike(
    $report,
    qr/sets [ ] [^\n]* GPFORUM_WEB_PROCESSES/msx,
    'and the file is not blamed on the shell'
);

local $ENV{GPFORUM_ENV}            = 'production';
local $ENV{GPFORUM_SESSION_SECRET} = 'short';
unlike(
    _report(),
    qr/secret [ ] rotate [ ] session/msx,
    'a secret the shell set is not offered a rotation of the file'
);

done_testing();

sub _report {
    my $problems;
    eval { GPForum::Config->from_environment; 1 }
      or $problems = $EVAL_ERROR->problems;

    return GPForum::Command::Support::Words->new->config_report( $problems,
        GPForum::Command::Support::ServiceEnvironment->loaded );
}

1;
