# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';

use GPForum::Bootstrap::Operations;
use GPForum::Config;
use GPForum::OS::RuntimePolicy;
use GPForum::Runtime;
use GPForum::X::Check;
use Mojolicious;

our $VERSION = '0.001';

const my $HTTP_OK                => 200;
const my $OVER_SEARCH_BUDGET     => 4;
const my $CLIENT_TIMEOUT_SECONDS => 1;
const my @SERVER_ENVIRONMENTS => qw(
  production
  production-small
  production-medium
  staging
);
const my @LOCAL_ENVIRONMENTS => qw(development test testing);

# GPFORUM_QUERY_BUDGET_ENFORCE=1 turns a breached budget into a failed
# response, for tests and benchmarks. Every server profile ignores it: only
# the name 'production' used to, so production-small, production-medium and
# staging failed real responses when the flag was left set on a server.
local $ENV{GPFORUM_QUERY_BUDGET_ENFORCE}    = 1;
local $ENV{GPFORUM_BENCHMARK_QUERY_HEADERS} = 1;

# Production never sends the benchmark headers, whatever the environment says
# (they would show every client how the database is queried); staging still
# shows the breach it observed.
for my $environment (@SERVER_ENVIRONMENTS) {
    my $client   = _over_budget_client($environment);
    my $observed = $environment =~ /\A production/msx ? undef : 'fail';
    $client->{test}->get_ok('/__budget/search')
      ->status_is( $HTTP_OK, "$environment ignores the enforcement flag" )
      ->header_is(
        'X-GPForum-DB-Budget' => $observed,
        $observed
        ? "$environment still shows the breach"
        : "$environment sends no benchmark header"
      );
    is_deeply( $client->{errors}, [], "$environment raises nothing" );
}

# The hook throws after the response is rendered, so the client gets no
# response at all: it waits out its inactivity timeout, kept short here.
for my $environment (@LOCAL_ENVIRONMENTS) {
    my $client = _over_budget_client($environment);
    my $tx     = $client->{test}->ua->get('/__budget/search');
    ok( !$tx->res->code,
        "$environment fails the response that breaks its budget" );
    like(
        join( q{ }, @{ $client->{errors} } ),
        qr/query [ ] budget [ ] exceeded:search:queries/msx,
        "$environment names the endpoint and the breach"
    );
    ok(
        GPForum::X::Check->caught( $client->{errors}[0] ),
        "$environment raises it as a failed check"
    );
    is(
        "$client->{errors}[0]",
        'query budget exceeded:search:queries',
        'its text is the breach alone, with no file and line'
    );
}

{
    local $ENV{GPFORUM_QUERY_BUDGET_ENFORCE} = 0;
    my $client = _over_budget_client('development');
    $client->{test}->get_ok('/__budget/search')
      ->status_is( $HTTP_OK, 'without the flag a breach only shows' )
      ->header_is( 'X-GPForum-DB-Budget' => 'fail' );
}

done_testing();

# An application whose route is named like the search page (a budget of 3)
# and records four statements, so every request breaks its budget. What the
# dispatch throws is recorded and kept there: thrown on, it only reaches
# Mojolicious to fail rendering a second response, on stderr.
sub _over_budget_client {
    my ($environment) = @_;

    my $config = GPForum::Config->new(
        environment    => $environment,
        glifistore_url => q{},
        log_level      => 'fatal',
    );
    my $runtime     = GPForum::Runtime->new;
    my $application = Mojolicious->new;
    $application->log->level('fatal');
    $application->secrets( ["query-budget-enforcement-$environment"] );
    GPForum::Bootstrap::Operations->register(
        application    => $application,
        config         => $config,
        runtime        => $runtime,
        runtime_policy => GPForum::OS::RuntimePolicy->new(
            config  => $config,
            runtime => $runtime,
        ),
    );
    my @errors;
    $application->hook(
        around_dispatch => sub {
            my ( $next, $controller ) = @_;

            try {
                $next->();
            }
            catch ($error) {
                push @errors, $error;

                return 0;
            };

            return 1;
        }
    );
    my $route = $application->routes->get('/__budget/search');
    $route->to(
        cb => sub {
            my ($controller) = @_;

            my $stats = $controller->gp_db_query_stats;
            for my $statement ( 1 .. $OVER_SEARCH_BUDGET ) {
                $stats->query_start("SELECT $statement");
            }

            return $controller->render( text => 'ok' );
        }
    )->name('forum_search');

    my $test = Test::Mojo->new($application);
    $test->ua->inactivity_timeout($CLIENT_TIMEOUT_SECONDS);

    return { errors => \@errors, test => $test };
}

1;
