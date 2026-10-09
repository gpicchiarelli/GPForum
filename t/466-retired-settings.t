# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Mojolicious;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Bootstrap::Config;
use GPForum::Bootstrap::Operations;
use GPForum::Config;
use GPForum::OS::RuntimePolicy;
use GPForum::Runtime;
use GPForum::Service::Operations::Profile;

our $VERSION = '0.001';

const my $HTTP_OK => 200;
const my $WORKERS => 3;

# production-medium's floors for the settings that are not retired; 64 web
# processes a CPU let any host carry its 8.
const my $MEDIUM_CACHE    => 4_096;
const my $MEDIUM_WEB      => 8;
const my $WEB_PER_CPU     => 64;
const my $DEFAULT_WORKERS => 2;

# The settings the walkthrough found to have no effect (section 2.1, owner
# decision D2') are retired: an old environment file that still sets them
# starts, and the start says what to remove. And a benchmark's per-request
# database counts never reach a production client, whatever the environment
# says.

const my @RETIRED =>
  qw(GPFORUM_WORKER_PROCESSES GPFORUM_REALTIME_PROCESSES GPFORUM_OS_AFFINITY);

subtest 'a retired setting is read, and named' => sub {
    my $config = GPForum::Config->from_environment(
        {
            GPFORUM_WORKER_PROCESSES   => $WORKERS,
            GPFORUM_REALTIME_PROCESSES => q{},
            GPFORUM_OS_AFFINITY        => 'manual',
        }
    );
    is_deeply(
        $config->retired_settings,
        [qw(GPFORUM_WORKER_PROCESSES GPFORUM_OS_AFFINITY)],
        'those the environment sets, and not one left empty'
    );
    is( $config->worker_processes, $WORKERS,
        'still read, so nothing that asks breaks' );
    is_deeply( GPForum::Config->from_environment( {} )->retired_settings,
        [], 'an environment without them names none' );
    is_deeply(
        [
            map  { $_->{env} }
            grep { $_->{retired} } @{ GPForum::Config->settings }
        ],
        [@RETIRED],
        'the three the walkthrough found are retired'
    );
};

subtest 'the start warns once for each' => sub {
    my $application = Mojolicious->new;
    $application->log->level('warn');    # Test::Mojo asks for fatal alone
    my @warnings;
    $application->log->unsubscribe('message')->on(
        message => sub ( $, $level, @lines ) {
            if ( $level eq 'warn' ) {
                push @warnings, join q{ }, @lines;
            }
        }
    );
    GPForum::Bootstrap::Config->register(
        application => $application,
        config      => GPForum::Config->from_environment(
            { map { $_ => '1' } @RETIRED[ 0 .. 1 ] }
        ),
    );
    is_deeply(
        \@warnings,
        [
            map {
                "$_ no longer has any effect; remove it from the environment"
                  . ' file.'
            } @RETIRED[ 0 .. 1 ]
        ],
        'naming the variable and what to do'
    );
};

subtest 'an old environment file never stops a start' => sub {
    my $config;
    my $refused = q{};
    try {
        $config = GPForum::Config->from_environment(
            {
                GPFORUM_WORKER_PROCESSES   => 'four',
                GPFORUM_REALTIME_PROCESSES => '9999',
                GPFORUM_OS_AFFINITY        => 'pinned',
            }
        );
    }
    catch ($error) {
        $refused = "$error";
    };
    is( $refused, q{}, 'whatever a retired setting holds' );
    is_deeply( $config && $config->retired_settings,
        [@RETIRED], 'and the start still names each one to remove' );
    is( $config && $config->worker_processes,
        $DEFAULT_WORKERS, 'one that does not parse keeps its default' );
    is_deeply( GPForum::Config->new( worker_processes => 0 )->problems,
        [], 'and no value of one is a problem' );
};

subtest 'removing them keeps the profile met' => sub {
    my $profile = GPForum::Service::Operations::Profile->new->evaluate(
        GPForum::Config->new(
            environment             => 'production-medium',
            session_secret          => 'rotated-production-secret',
            local_cache_max_entries => $MEDIUM_CACHE,
            runtime_max_web_per_cpu => $WEB_PER_CPU,
            web_processes           => $MEDIUM_WEB,
        )
    );
    ok( $profile->{ok},
            'production-medium at its default worker and realtime counts,'
          . ' which nothing starts' )
      or diag explain $profile->{errors};
};

subtest 'production never sends the benchmark query headers' => sub {
    local $ENV{GPFORUM_BENCHMARK_QUERY_HEADERS} = 1;
    my $development = _client( GPForum::Config->new( log_level => 'fatal' ) );
    $development->get_ok('/plain')->status_is($HTTP_OK)->header_like(
        'X-GPForum-DB-Queries' => qr/\A \d+ \z/msx,
        'development sends them when asked'
    );

    my $production = _client(
        GPForum::Config->new(
            environment => 'production',
            log_level   => 'fatal',
        )
    );
    $production->get_ok('/plain')->status_is($HTTP_OK)->header_is(
        'X-GPForum-DB-Queries' => undef,
        'production never does'
    );
};

done_testing();

# An application with only the operations bootstrap and one plain route.
sub _client ($config) {
    my $runtime     = GPForum::Runtime->new;
    my $application = Mojolicious->new;
    $application->log->level('fatal');
    $application->secrets( ['retired-settings'] );
    GPForum::Bootstrap::Operations->register(
        application    => $application,
        config         => $config,
        runtime        => $runtime,
        runtime_policy => GPForum::OS::RuntimePolicy->new(
            config  => $config,
            runtime => $runtime,
        ),
    );
    $application->routes->get('/plain')
      ->to( cb => sub ($controller) { $controller->render( text => 'ok' ) } );

    return Test::Mojo->new($application);
}

1;
