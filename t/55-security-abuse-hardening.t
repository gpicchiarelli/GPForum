package main;

use strict;
use warnings;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Community::MentionStore;
use GPForum::Service::Moderation::ReportStore;
use GPForum::Service::Operations::RateLimiter;
use GPForum::Service::Operations::RateLimiter::PostgreSQLStore;
use GPForum::Service::Operations::SecurityTelemetry;
use GPForum::Test::AdminWebServices;
use GPForum::Test::AllowPermissionGate;
use GPForum::Test::DenyPermissionGate;
use GPForum::Test::FailingRateLimitStore;
use GPForum::Test::FixedClock;
use GPForum::Test::ForumWebServices;
use GPForum::Test::Id;
use GPForum::Test::IdentityStore;
use GPForum::Test::RateLimitSchema;
use GPForum::Test::Schema;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_CREATED      => 201;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_TOO_MANY     => 429;

subtest 'rate limiter degrades to local store and audits blocked events' =>
  sub {
    my $schema    = GPForum::Test::Schema->new;
    my $telemetry = GPForum::Service::Operations::SecurityTelemetry->new(
        clock => GPForum::Test::FixedClock->new, );
    my $limiter = GPForum::Service::Operations::RateLimiter->new(
        clock              => GPForum::Test::FixedClock->new,
        id_service         => GPForum::Test::Id->new,
        primary_store      => GPForum::Test::FailingRateLimitStore->new,
        schema             => $schema,
        security_telemetry => $telemetry,
    );

    my $first = $limiter->check( _limit_input() );
    ok( $first->{ok},       'fallback allows first request' );
    ok( $first->{degraded}, 'fallback decision is marked degraded' );

    my $second = $limiter->check( _limit_input() );
    ok( !$second->{ok}, 'fallback enforces limit after primary failure' );

    my $snapshot = $limiter->snapshot;
    is( $snapshot->{stats}{primary_failures},
        2, 'limiter counts primary store failures' );
    is( $snapshot->{stats}{fallback_used},
        2, 'limiter counts degraded fallback usage' );
    is( $snapshot->{stats}{blocked}, 1, 'limiter counts blocked requests' );
    is( $schema->created_for('AuditLog')->[0]{action},
        'rate_limit.blocked', 'blocked rate limit writes audit record' );
    is( $telemetry->snapshot->{events}{rate_limit_hit}{count},
        1, 'telemetry records rate limit hit' );
  };

subtest 'postgres rate limiter uses shared atomic upsert semantics' => sub {
    my $schema = GPForum::Test::RateLimitSchema->new;
    my $first_store =
      GPForum::Service::Operations::RateLimiter::PostgreSQLStore->new(
        clock  => GPForum::Test::FixedClock->new,
        schema => $schema,
      );
    my $second_store =
      GPForum::Service::Operations::RateLimiter::PostgreSQLStore->new(
        clock  => GPForum::Test::FixedClock->new,
        schema => $schema,
      );

    my %first_input = %{ _limit_input() };
    $first_input{limit} = 1;
    my %second_input = %{ _limit_input() };
    $second_input{limit} = 1;
    my $first  = $first_store->check( \%first_input );
    my $second = $second_store->check( \%second_input );

    ok( $first->{ok},   'first process-shaped store allows shared bucket' );
    ok( !$second->{ok}, 'second process-shaped store observes shared bucket' );
    like(
        $schema->dbh->calls->[0]{sql},
        qr/ON [ ] CONFLICT/msx,
        'PostgreSQL store uses atomic upsert'
    );
};

subtest 'mention fanout is bounded and audit-backed' => sub {
    my $schema = GPForum::Test::Schema->new( users => _mention_users(12), );
    my $store  = GPForum::Service::Community::MentionStore->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
        schema     => $schema,
    );

    my $result = $store->record_for_source(
        {
            actor_id     => 'actor-1',
            body_source  => _mention_body(12),
            max_mentions => 5,
            source_id    => 'post-1',
            source_type  => 'post',
            thread_id    => 'thread-1',
        }
    );

    is( scalar @{ $result->{created} },
        5, 'mention store creates only allowed fanout' );
    is( scalar @{ $result->{skipped} },
        7, 'mention store skips excess mentions' );
    is( $result->{skipped}[0]{reason},
        'fanout_limited', 'skipped mentions name fanout limit' );
    is( $schema->created_for('AuditLog')->[0]{action},
        'mention.fanout_limited', 'mention fanout limit writes audit record' );
};

subtest 'duplicate reports are blocked without duplicate domain events' => sub {
    my $schema = GPForum::Test::Schema->new(
        reports => [
            {
                created_at       => '2026-05-23T12:00:00Z',
                reason           => 'spam',
                report_id        => 'report-existing',
                reporter_user_id => 'user-1',
                status           => 'open',
                target_id        => 'post-1',
                target_type      => 'post',
            },
        ],
    );
    my $store = GPForum::Service::Moderation::ReportStore->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
        schema     => $schema,
    );

    my $report = $store->create_report(
        {
            details          => 'same target',
            reason           => 'spam',
            reporter_user_id => 'user-1',
            target_id        => 'post-1',
            target_type      => 'post',
        }
    );

    is( $report->{report_id},
        'report-existing', 'duplicate report returns existing open report' );
    is( scalar @{ $schema->created_for('EventLog') },
        0, 'duplicate report does not create duplicate domain event' );
    is( $schema->created_for('AuditLog')->[0]{action},
        'report.duplicate_blocked', 'duplicate report writes audit record' );
};

subtest 'authorization denial matrix returns explicit statuses' => sub {
    my $test = _security_test_app();
    _install_test_session_route($test);

    $test->get_ok( '/admin' => { Accept => 'application/json' } );
    $test->status_is( $HTTP_UNAUTHORIZED, 'anonymous admin read is 401' );
    $test->get_ok( '/moderation/reports' => { Accept => 'application/json' } );
    $test->status_is( $HTTP_UNAUTHORIZED, 'anonymous moderation read is 401' );
    $test->get_ok( '/notifications' => { Accept => 'application/json' } );
    $test->status_is( $HTTP_UNAUTHORIZED,
        'anonymous notification read is 401' );

    $test->post_ok(
        '/threads' => { Accept => 'application/json' } => form => {
            csrf_token  => _csrf_token($test),
            category_id => 'category-1',
            title       => 'Denied',
            body_source => 'Denied',
            visibility  => 'public',
        }
    );
    $test->status_is( $HTTP_UNAUTHORIZED,
        'anonymous forum write with CSRF is 401' );

    $test->get_ok('/__test/session/user-normal');
    $test->status_is($HTTP_OK);
    $test->app->helper(
        gp_permission_gate => sub {
            return GPForum::Test::DenyPermissionGate->new;
        }
    );

    $test->get_ok( '/admin' => { Accept => 'application/json' } );
    $test->status_is( $HTTP_FORBIDDEN, 'normal admin read denial is 403' );
    $test->get_ok( '/moderation/reports' => { Accept => 'application/json' } );
    $test->status_is( $HTTP_FORBIDDEN, 'normal moderation read denial is 403' );
};

subtest 'anti-leak surfaces exclude hidden content in SSR and JSON' => sub {
    my $test = _security_test_app();
    _install_test_session_route($test);

    $test->get_ok('/feed.atom');
    $test->status_is($HTTP_OK);
    $test->content_unlike(qr/private [ ] text [ ] must [ ] not [ ] leak/msx);

    $test->get_ok('/sitemap.xml');
    $test->status_is($HTTP_OK);
    $test->content_unlike(qr/thread-hidden/msx);

    $test->get_ok( '/search?q=hidden' => { Accept => 'application/json' } );
    $test->status_is($HTTP_OK);
    $test->content_unlike(qr/private [ ] text [ ] must [ ] not [ ] leak/msx);

    $test->get_ok(
        '/search/autocomplete?q=hidden' => { Accept => 'application/json' } );
    $test->status_is($HTTP_OK);
    $test->content_unlike(qr/private [ ] text [ ] must [ ] not [ ] leak/msx);

    $test->get_ok('/c/category-1');
    $test->status_is($HTTP_OK);
    $test->content_unlike(qr/private [ ] text [ ] must [ ] not [ ] leak/msx);

    $test->get_ok( '/c/category-1' => { Accept => 'application/json' } );
    $test->status_is($HTTP_OK);
    $test->content_unlike(qr/private [ ] text [ ] must [ ] not [ ] leak/msx);

    $test->get_ok('/t/thread-1');
    $test->status_is($HTTP_OK);
    $test->content_unlike(qr/private [ ] text [ ] must [ ] not [ ] leak/msx);

    $test->get_ok( '/t/thread-1' => { Accept => 'application/json' } );
    $test->status_is($HTTP_OK);
    $test->content_unlike(qr/private [ ] text [ ] must [ ] not [ ] leak/msx);

    $test->get_ok('/u/giacomo');
    $test->status_is($HTTP_OK);
    $test->content_unlike(qr/private [ ] text [ ] must [ ] not [ ] leak/msx);

    $test->get_ok( '/u/giacomo' => { Accept => 'application/json' } );
    $test->status_is($HTTP_OK);
    $test->content_unlike(qr/private [ ] text [ ] must [ ] not [ ] leak/msx);

    $test->get_ok('/__test/session/user-1');
    $test->status_is($HTTP_OK);
    $test->get_ok('/notifications');
    $test->status_is($HTTP_OK);
    $test->content_unlike(qr/private [ ] text [ ] must [ ] not [ ] leak/msx);

    $test->get_ok( '/notifications' => { Accept => 'application/json' } );
    $test->status_is($HTTP_OK);
    $test->content_unlike(qr/private [ ] text [ ] must [ ] not [ ] leak/msx);
};

subtest 'security metrics expose safe counters' => sub {
    my $test = _security_test_app();

    $test->post_ok('/threads');
    $test->status_is($HTTP_FORBIDDEN);
    $test->get_ok('/metrics');
    $test->status_is($HTTP_OK);
    $test->json_is( '/security/events/csrf_failure/count' => 1 );
    $test->json_has('/security/events/csrf_failure/last_metadata/route');
};

done_testing();

sub _security_test_app {
    my $test = Test::Mojo->new('GPForum');
    _install_forum_fakes($test);
    _install_admin_fakes($test);
    my $identity = GPForum::Test::IdentityStore->new( invalid_login => 1 );
    $test->app->helper(
        gp_identity_store => sub {
            return $identity;
        }
    );
    $test->app->helper(
        gp_profile_reader => sub {
            return $identity;
        }
    );

    return $test;
}

sub _install_forum_fakes {
    my ($test) = @_;

    my $services = GPForum::Test::ForumWebServices->new;
    for my $helper (
        qw(
        gp_category_reader gp_thread_reader gp_thread_detail_reader
        gp_thread_composer gp_thread_store gp_post_reader gp_post_composer
        gp_post_store gp_post_position gp_thread_read_state gp_mention_store
        gp_mention_reader gp_bookmark_store gp_subscription_store
        gp_notification_dispatcher gp_report_store gp_search_service
        gp_suspension_store gp_moderation_action_store
        gp_moderation_review_reader
        )
      )
    {
        $test->app->helper( $helper => sub { return $services; } );
    }
    $test->app->helper(
        gp_feed_reader => sub {
            return GPForum::Test::ForumWebServices->new( mode => 'feed' );
        }
    );

    return;
}

sub _install_admin_fakes {
    my ($test) = @_;

    my $services = GPForum::Test::AdminWebServices->new;
    $test->app->helper( gp_role_catalog       => sub { return $services; } );
    $test->app->helper( gp_role_binding_store => sub { return $services; } );
    $test->app->helper( gp_permission_review  => sub { return $services; } );
    $test->app->helper( gp_admin_audit_review => sub { return $services; } );
    $test->app->helper(
        gp_permission_gate => sub {
            return GPForum::Test::AllowPermissionGate->new;
        }
    );

    return;
}

sub _install_test_session_route {
    my ($test) = @_;

    $test->app->routes->get('/__test/session/:user_id')->to(
        cb => sub {
            my ($controller) = @_;

            $controller->session(
                session_expires_at_epoch => time + 3_600,
                user_id                  => $controller->param('user_id'),
            );
            return $controller->render( json => { ok => 1 } );
        }
    );

    return;
}

sub _csrf_token {
    my ($test) = @_;

    $test->get_ok('/new-thread?format=json');
    $test->status_is($HTTP_OK);

    return $test->tx->res->json->{csrf_token};
}

sub _limit_input {
    return {
        action         => 'thread.create',
        actor_id       => 'user-1',
        limit          => 1,
        scope          => 'forum_http',
        window_seconds => 60,
    };
}

sub _mention_users {
    my ($count) = @_;

    my @users;
    for my $index ( 1 .. $count ) {
        push @users,
          {
            id         => 'user-' . $index,
            username   => sprintf( 'user%03d', $index ),
            deleted_at => undef,
          };
    }

    return \@users;
}

sub _mention_body {
    my ($count) = @_;

    return join q{ }, map { sprintf '@user%03d', $_ } 1 .. $count;
}

1;
