# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use English qw(-no_match_vars);
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Bootstrap::Operations;
use GPForum::Config;
use GPForum::OS::RuntimePolicy;
use GPForum::Runtime;
use GPForum::Service::Operations::QueryBudget;
use GPForum::Test::Id;
use Mojolicious;

our $VERSION = '0.001';

# The request hooks Bootstrap::Operations installs: the request id each
# response carries, the endpoint a route's queries are budgeted under, and
# the benchmark headers that report it. Each is pinned on its own rather
# than through the one route t/69 renders.

const my $LONGEST_REQUEST_ID => 128;
const my $HTTP_NOT_FOUND     => 404;
const my $FALLBACK_ID        => qr/\A gpforum - $PROCESS_ID - \d+ - \d+ \z/msx;

# Every route the budgets know, and the endpoint it is counted under.
const my %ENDPOINT_FOR => (
    admin_audit                  => 'admin_audit',
    admin_dashboard              => 'admin_dashboard',
    admin_dead_letter_replay     => 'admin_role_update',
    admin_jobs                   => 'admin_jobs',
    admin_permission_create      => 'admin_role_update',
    admin_role_bind              => 'admin_role_update',
    admin_role_binding_revoke    => 'admin_role_update',
    admin_role_create            => 'admin_role_update',
    admin_role_permission_attach => 'admin_role_update',
    admin_roles                  => 'admin_roles',
    admin_status                 => 'admin_status',
    admin_user_roles             => 'admin_user_roles',
    admin_users                  => 'admin_users',
    attachment_download          => 'thread_view',
    categories                   => 'categories',
    category                     => 'category_threads',
    forum_search                 => 'search',
    home                         => 'home',
    metrics                      => 'metrics',
    moderation_action_reverse    => 'moderation_action',
    moderation_actions           => 'moderation_actions',
    moderation_post_hide         => 'moderation_action',
    moderation_post_restore      => 'moderation_action',
    moderation_report_assign     => 'report_update',
    moderation_report_release    => 'report_update',
    moderation_report_resolve    => 'report_update',
    moderation_reports           => 'moderation_reports',
    moderation_suspension_revoke => 'user_suspension',
    moderation_suspensions       => 'moderation_suspensions',
    moderation_thread_hide       => 'moderation_action',
    moderation_thread_lock       => 'moderation_action',
    moderation_thread_restore    => 'moderation_action',
    moderation_thread_unlock     => 'moderation_action',
    moderation_user_suspend      => 'user_suspension',
    notification_read            => 'notifications',
    notifications                => 'notifications',
    post_attachment_upload       => 'reply_create',
    post_report                  => 'report_create',
    privacy_deletion_approve     => 'admin_role_update',
    privacy_deletion_hold        => 'admin_role_update',
    privacy_erasure_run          => 'admin_role_update',
    privacy_review               => 'admin_dashboard',
    profile_report               => 'report_create',
    reply_create                 => 'reply_create',
    search_autocomplete          => 'search_autocomplete',
    thread                       => 'thread_view',
    thread_canonical             => 'thread_view',
    thread_create                => 'thread_create',
    thread_report                => 'report_create',
);

local $ENV{GPFORUM_BENCHMARK_QUERY_HEADERS} = 1;
local $ENV{GPFORUM_QUERY_BUDGET_ENFORCE}    = 0;

subtest 'a request id is kept only when it is short and plain' => sub {
    my $test = _client();
    my $kept = 'a' x $LONGEST_REQUEST_ID;

    is( _request_id( $test, 'Req_1.2:3-4' ),
        'Req_1.2:3-4', 'letters, digits and _ . : - are kept' );
    is( _request_id( $test, $kept ), $kept, '128 characters are kept' );
    for my $refused ( 'a' x ( $LONGEST_REQUEST_ID + 1 ), 'has space', q{0} ) {
        like( _request_id( $test, $refused ),
            $FALLBACK_ID, "'$refused' is replaced by a process-local id" );
    }
    like( _request_id($test), $FALLBACK_ID, 'and so is a missing one' );

    my ( $earlier, $later ) =
      map { _request_id($test) =~ /(\d+) \z/msx } 1 .. 2;
    is( $later, $earlier + 1, 'the process-local ids count up' );
};

subtest 'the id service names a request when there is one' => sub {
    my $id   = GPForum::Test::Id->new;
    my $test = _client(
        sub ($application) {
            $application->helper( gp_id => sub { return $id; } );
        }
    );

    is( _request_id( $test, 'has space' ),
        'generated-1', 'a refused header gets a uuid from gp_id' );
    is( _request_id( $test, 'kept-id' ), 'kept-id', 'a safe header is kept' );
    is( $id->value, 1, 'gp_id is asked only when the header is refused' );
};

subtest 'each named route is budgeted under its endpoint' => sub {
    my $budgets = GPForum::Service::Operations::QueryBudget->new;
    my $test    = _client(
        sub ($application) {
            my $routes = $application->routes;
            for my $route ( sort keys %ENDPOINT_FOR ) {
                my $get = $routes->get("/route/$route");
                $get->to( cb => \&_render_ok );
                $get->name($route);
            }
        }
    );

    for my $route ( sort keys %ENDPOINT_FOR ) {
        my $endpoint = $ENDPOINT_FOR{$route};
        is_deeply(
            _budget_headers( $test, "/route/$route" ),
            {
                'X-GPForum-DB-Budget'             => 'ok',
                'X-GPForum-DB-Budget-Endpoint'    => $endpoint,
                'X-GPForum-DB-Budget-Max-Queries' =>
                  $budgets->budget_for($endpoint)->{max_queries},
                'X-GPForum-DB-Duplicate-Queries' => 0,
                'X-GPForum-DB-Queries'           => 0,
                'X-GPForum-DB-Transactions'      => 0,
            },
            "$route is counted as $endpoint"
        );
    }
};

subtest 'a route with no budget reports none' => sub {
    is_deeply(
        _budget_headers( _client(), '/plain' ),
        {
            'X-GPForum-DB-Budget'             => 'none',
            'X-GPForum-DB-Budget-Endpoint'    => 'none',
            'X-GPForum-DB-Budget-Max-Queries' => 'none',
            'X-GPForum-DB-Duplicate-Queries'  => 0,
            'X-GPForum-DB-Queries'            => 0,
            'X-GPForum-DB-Transactions'       => 0,
        },
        'every benchmark header, none budgeted'
    );
};

subtest 'each request is recorded with its route, status and budget' => sub {
    my $test = _client(
        sub ($application) {
            my $thread = $application->routes->get('/route/thread');
            $thread->to( cb => \&_render_ok );
            $thread->name('thread');
        }
    );
    my $stats = $test->app->build_controller->gp_db_query_stats;

    $test->ua->get('/route/thread');
    my $budgeted = $stats->last_request;
    is_deeply(
        [ @{$budgeted}{qw(route endpoint_name status query_budget_status)} ],
        [qw(thread thread_view 200 ok)],
        'a named route: its name, its endpoint, the status and the verdict'
    );

    $test->ua->get('/nowhere');
    my $unmatched = $stats->last_request;
    is_deeply(
        [ @{$unmatched}{qw(route status)} ],
        [ 'unknown', $HTTP_NOT_FOUND ],
        'a request no route matched is recorded as unknown'
    );
    ok(
        !defined $unmatched->{endpoint_name}
          && !defined $unmatched->{query_budget_status},
        'with no endpoint and no verdict'
    );
};

subtest 'the benchmark headers need their flag' => sub {
    local $ENV{GPFORUM_BENCHMARK_QUERY_HEADERS} = 'yes';
    my $test = _client();

    is_deeply( _budget_headers( $test, '/plain' ),
        {}, 'only the value 1 turns them on' );
    like( _request_id($test), qr/\S/msx, 'the request id is sent regardless' );
};

done_testing();

# An application with only the operations bootstrap and one plain route;
# $extend adds helpers or routes before the client is built.
sub _client ( $extend = undef ) {
    my $config = GPForum::Config->new(
        environment => 'testing',
        log_level   => 'fatal',
    );
    my $runtime     = GPForum::Runtime->new;
    my $application = Mojolicious->new;
    $application->log->level('fatal');
    $application->secrets( ['bootstrap-operations-request-hooks'] );
    GPForum::Bootstrap::Operations->register(
        application    => $application,
        config         => $config,
        runtime        => $runtime,
        runtime_policy => GPForum::OS::RuntimePolicy->new(
            config  => $config,
            runtime => $runtime,
        ),
    );
    $application->routes->get('/plain')->to( cb => \&_render_ok );
    if ($extend) {
        $extend->($application);
    }

    return Test::Mojo->new($application);
}

sub _render_ok ($controller) {
    return $controller->render( text => 'ok' );
}

# The X-Request-ID a GET of /plain answers, sent with $sent when given.
sub _request_id ( $test, $sent = undef ) {
    my $headers = defined $sent ? { 'X-Request-ID' => $sent } : {};
    my $tx      = $test->ua->get( '/plain' => $headers );

    return $tx->res->headers->header('X-Request-ID');
}

# The X-GPForum-DB-* headers a GET of $path answers.
sub _budget_headers ( $test, $path ) {
    my $tx      = $test->ua->get($path);
    my $headers = $tx->res->headers;

    return {
        map  { $_ => $headers->header($_) }
        grep { /\A X-GPForum-DB- /msx } @{ $headers->names }
    };
}

1;
