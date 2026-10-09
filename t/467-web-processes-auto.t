# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use List::Util qw(min);
use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Config::Report;
use GPForum::OS;
use GPForum::OS::CpuCount;
use GPForum::Service::Operations::Profile;
use GPForum::Test::SmallHostConfig;
use GPForum::Test::UncountedConfig;

our $VERSION = '0.001';

# GPFORUM_WEB_PROCESSES defaulted to 4 whatever the host: above what one CPU
# carries, so the shipped preflight refused a 1-vCPU VPS, and below what a
# large host could run (walkthrough, item 3; audit item A7). It defaults to
# auto now: as many as the CPUs carry under cap-to-cpu, at most 16.

const my $MOST         => 16;
const my $CHOSEN       => 3;
const my $PER_CPU      => 3;
const my $SMALL_HOST   => 2;
const my $COUNTED_CPUS => 7;

# The CPUs the host's profile counts for a worker: every logical CPU, or
# fewer on a Mac with efficiency cores (OS::Darwin::worker_cpu_count).
my $cpus = GPForum::OS->detect->worker_cpu_count;

subtest 'auto is the default, and what the host carries' => sub {
    my $config = GPForum::Config->from_environment( {} );
    is(
        $config->web_processes,
        $config->automatic_web_processes,
        'an unset GPFORUM_WEB_PROCESSES is auto'
    );
    is(
        $config->automatic_web_processes,
        min( $MOST, $cpus * 2 ),
        "two a CPU on this host's $cpus, at most $MOST"
    );
    is(
        GPForum::Config->from_environment(
            { GPFORUM_RUNTIME_MAX_WEB_PER_CPU => $PER_CPU }
        )->web_processes,
        min( $MOST, $cpus * $PER_CPU ),
        'at GPFORUM_RUNTIME_MAX_WEB_PER_CPU a CPU'
    );
    for my $word (qw(auto AUTO Auto)) {
        is(
            GPForum::Config->from_environment(
                { GPFORUM_WEB_PROCESSES => $word }
            )->web_processes,
            $config->automatic_web_processes,
            "$word reads as auto"
        );
    }
    is(
        GPForum::Config->from_environment(
            { GPFORUM_WEB_PROCESSES => $CHOSEN }
        )->web_processes,
        $CHOSEN,
        'a number is taken as it is'
    );
};

subtest 'anything else is refused, saying auto is allowed' => sub {
    my $refused;
    try {
        GPForum::Config->from_environment(
            { GPFORUM_WEB_PROCESSES => 'lots' } );
    }
    catch ($error) {
        $refused = $error;
    };
    is(
        GPForum::Config::Report->sentence( $refused->problems->[0] ),
        q{GPFORUM_WEB_PROCESSES must be a whole number or auto, not 'lots'.},
        'naming both'
    );
};

subtest 'checking a configuration does not count the CPUs' => sub {
    lives_ok { GPForum::Test::UncountedConfig->new->validate }
    'validate leaves auto alone';
    lives_ok { GPForum::Test::UncountedConfig->from_environment( {} ) }
    'and so does reading the environment';
    throws_ok { GPForum::Test::UncountedConfig->new->web_processes }
    qr/counted [ ] the [ ] CPUs/msx, 'the count is made when it is read';
};

subtest q{a profile's web floor is what the host carries, when that is less} =>
  sub {
    my $profiles = GPForum::Service::Operations::Profile->new;
    my $small    = $profiles->evaluate(
        GPForum::Test::SmallHostConfig->new(
            environment    => 'production-small',
            session_secret => 'rotated-production-secret',
        )
    );
    ok( $small->{ok}, 'auto on a two-process host meets production-small' );

    my $undersized = $profiles->evaluate(
        GPForum::Config->new(
            environment             => 'production-small',
            session_secret          => 'rotated-production-secret',
            runtime_max_web_per_cpu => $MOST,
            web_processes           => $SMALL_HOST,
        )
    );
    ok( $undersized->{errors}{web_processes},
        'two on a host that carries more is still below the floor' );
  };

subtest 'the CPUs are counted while standard output is captured' => sub {
    my $count;
    my $output = _stdout_of(
        sub {
            $count = GPForum::OS::CpuCount->new->detect(
                [
                    {
                        name    => 'echo',
                        type    => 'command',
                        command => [ '/bin/echo', $COUNTED_CPUS ],
                    }
                ],
                []
            )->{count};
            print {*STDOUT} 'still mine' or croak 'the capture was closed';
        }
    );
    is( $count,  $COUNTED_CPUS, 'the command is read' );
    is( $output, 'still mine',  'and the capture is left as it was' );
};

done_testing();

# What a piece of code writes to standard output.
sub _stdout_of ($code) {
    my $output = q{};
    open my $stdout, '>', \$output or croak 'capture stdout';
    {
        local *STDOUT = $stdout;
        $code->();
    }
    close $stdout or croak 'close stdout';

    return $output;
}

1;
