# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use List::Util qw(any);
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Operations::SecurityTelemetry;
use GPForum::Test::AdminWebServices;
use GPForum::Test::AllowLimiter;
use GPForum::Test::AllowPermissionGate;
use GPForum::Test::CommandIdempotency;
use GPForum::Test::DenyLimiter;
use GPForum::Test::DenyPermissionGate;
use GPForum::Test::ForumWebServices;
use GPForum::Test::IdentityStore;
use GPForum::Test::PrivacyWebServices;
use GPForum::Test::SuspendedParticipation;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_TOO_MANY     => 429;
const my $JSON              => { Accept => 'application/json' };
const my $REPORT_ID         => '018f1000-0000-7000-8000-0000000000a1';
const my $CSRF         => { status => $HTTP_FORBIDDEN };
const my $UNAUTHORIZED => { status => $HTTP_UNAUTHORIZED };
const my $FORBIDDEN    => { reason => 'forbidden', status => $HTTP_FORBIDDEN };
const my $TOO_MANY     => { status => $HTTP_TOO_MANY };

# Each controller base records the security event of each refusal it renders,
# on the route the request matched: a CSRF failure, a request with no member,
# a member without the permission, and one over the rate limit. A base that
# rendered the refusal without recording it would pass every status check and
# fail here.

my %double = (
    gate        => GPForum::Test::AllowPermissionGate->new,
    limiter     => GPForum::Test::AllowLimiter->new,
    suspensions => GPForum::Test::ForumWebServices->new,
    telemetry   => GPForum::Service::Operations::SecurityTelemetry->new,
);
my $test = Test::Mojo->new('GPForum');
$test->app->log->level(q{fatal});
_install_fakes( $test->app );

my @cases = (
    [ 'admin CSRF', 'POST', '/admin/roles', {}, csrf_failure => $CSRF ],
    [
        'admin no member',
        'GET', '/admin',
        { signed_out => 1 },
        auth_denial => $UNAUTHORIZED
    ],
    [
        'admin permission',
        'GET',
        '/admin',
        { denied => 1 },
        auth_denial => $FORBIDDEN
    ],
    [
        'admin rate limit',
        'POST',
        '/admin/roles',
        { limited => 1 },
        rate_limit_hit => $TOO_MANY
    ],
    [
        'moderation CSRF', 'POST',
        "/moderation/reports/$REPORT_ID/assign", {},
        csrf_failure => $CSRF
    ],
    [
        'moderation no member',
        'GET',
        '/moderation/reports',
        { signed_out => 1 },
        auth_denial => $UNAUTHORIZED
    ],
    [
        'moderation permission',
        'GET',
        '/moderation/reports',
        { denied => 1 },
        auth_denial => $FORBIDDEN
    ],
    [
        'moderation rate limit',
        'POST',
        "/moderation/reports/$REPORT_ID/assign",
        { limited => 1 },
        rate_limit_hit => $TOO_MANY
    ],
    [ 'forum CSRF', 'POST', '/threads', {}, csrf_failure => $CSRF ],
    [
        'forum no member',
        'POST',
        '/threads',
        { signed_out => 1 },
        auth_denial => $UNAUTHORIZED
    ],
    [
        'forum suspension',
        'POST',
        '/threads',
        { suspended => 1 },
        auth_denial => $FORBIDDEN
    ],
    [
        'forum rate limit',
        'POST',
        '/threads',
        { limited => 1 },
        rate_limit_hit => $TOO_MANY
    ],
    [
        'notification CSRF', 'POST', '/notifications/read-all', {},
        csrf_failure => $CSRF
    ],
    [
        'notification no member',
        'GET',
        '/notifications',
        { signed_out => 1 },
        auth_denial => $UNAUTHORIZED
    ],
    [
        'notification rate limit',
        'POST',
        '/notifications/read-all',
        { limited => 1 },
        rate_limit_hit => $TOO_MANY
    ],
    [
        'privacy rate limit',
        'POST',
        '/privacy/export',
        { limited => 1 },
        rate_limit_hit => $TOO_MANY
    ],
    [ 'identity CSRF', 'POST', '/login', {}, csrf_failure => $CSRF ],
    [
        'identity rate limit',
        'POST',
        '/login',
        { limited => 1 },
        rate_limit_hit => $TOO_MANY
    ],
);

for my $case (@cases) {
    my ( $name, $method, $path, $setup, $event, $metadata ) = @{$case};
    subtest "$name records $event" => sub {
        my $before = _count($event);
        _request( $method, $path, $setup );
        $test->status_is( $metadata->{status} );
        is( _count($event), $before + 1, "one $event recorded" );
        my $recorded =
          { %{ $double{telemetry}->events->{$event}{last_metadata} } };
        my $route = delete $recorded->{route};
        ok( defined $route && length $route && $route ne 'unknown',
            'on the route the request matched' )
          or diag explain $route;
        is_deeply( $recorded, $metadata, 'with its status and reason' );
    };
}

subtest 'a suspended member is also recorded as blocked' => sub {
    my $before = _count('suspended_user_block');
    _request( 'POST', '/threads', { suspended => 1 } );
    $test->status_is($HTTP_FORBIDDEN);
    is(
        _count('suspended_user_block'),
        $before + 1,
        'one suspended_user_block recorded'
    );
    my $recorded =
      { %{ $double{telemetry}->events->{suspended_user_block}{last_metadata} }
      };
    delete $recorded->{route};
    is_deeply(
        $recorded,
        { action => 'thread.create', status => $HTTP_FORBIDDEN },
        'naming the action refused'
    );
};

subtest 'a refused login is recorded as an authentication denial' => sub {
    my $before = _count('auth_denial');
    _request(
        'POST', '/login',
        {
            form => {
                identifier => 'giacomo_forum',
                password   => 'wrong password',
                command_id => $REPORT_ID
            }
        }
    );
    $test->status_is($HTTP_UNAUTHORIZED);
    is( _count('auth_denial'), $before + 1, 'one auth_denial recorded' );
    my $recorded =
      { %{ $double{telemetry}->events->{auth_denial}{last_metadata} } };
    delete $recorded->{route};
    is_deeply(
        $recorded,
        { action => 'identity.login', status => $HTTP_UNAUTHORIZED },
        'naming the login action'
    );
};

done_testing();

# A fresh session each time: signed in as admin-1 unless the case is signed
# out, with a CSRF token on a write unless the case is the CSRF failure, and
# the gate, limiter and suspension store the case names.
sub _request ( $method, $path, $setup ) {
    $test->reset_session;
    if ( !$setup->{signed_out} ) {
        $test->get_ok('/__test/session/admin-1')->status_is($HTTP_OK);
    }
    my %form = %{ $setup->{form} || {} };
    if ( $method eq 'POST' && !_csrf_case($setup) ) {
        $test->get_ok( '/__test/csrf' => $JSON )->status_is($HTTP_OK);
        my $response = $test->tx->res;
        $form{csrf_token} = $response->json->{csrf_token};
    }

    $double{gate} =
      $setup->{denied}
      ? GPForum::Test::DenyPermissionGate->new
      : GPForum::Test::AllowPermissionGate->new;
    $double{limiter} =
      $setup->{limited}
      ? GPForum::Test::DenyLimiter->new
      : GPForum::Test::AllowLimiter->new;
    $double{suspensions} =
      $setup->{suspended}
      ? GPForum::Test::SuspendedParticipation->new
      : GPForum::Test::ForumWebServices->new;

    if ( $method eq 'POST' ) {
        return $test->post_ok( $path => $JSON => form => \%form );
    }

    return $test->get_ok( $path => $JSON );
}

# A write with nothing else to refuse it is the CSRF case.
sub _csrf_case ($setup) {
    return !any { $setup->{$_} } qw(denied form limited signed_out suspended);
}

sub _count ($event) {
    my $recorded = $double{telemetry}->events->{$event};

    return $recorded ? $recorded->{count} : 0;
}

sub _install_fakes ($application) {
    my $admin   = GPForum::Test::AdminWebServices->new;
    my $forum   = GPForum::Test::ForumWebServices->new;
    my $privacy = GPForum::Test::PrivacyWebServices->new;
    my %fakes   = (
        (
            map { $_ => $admin }
              qw(gp_role_catalog gp_category_store gp_role_binding_store
              gp_permission_review gp_admin_audit_review
              gp_admin_console_reader gp_dead_letter_replay
              gp_admin_maintenance)
        ),
        (
            map { $_ => $forum }
              qw(gp_category_reader gp_thread_reader gp_thread_detail_reader
              gp_post_reader gp_post_position gp_thread_read_state
              gp_mention_reader gp_notification_dispatcher gp_report_store
              gp_moderation_action_store gp_moderation_review_reader
              gp_attachment_store gp_home_page_reader)
        ),
        gp_data_rights_review  => $privacy,
        gp_command_idempotency => GPForum::Test::CommandIdempotency->new,
        gp_identity_store      => GPForum::Test::IdentityStore->new(
            invalid_login => 1
        ),
    );
    for my $helper ( sort keys %fakes ) {
        my $fake = $fakes{$helper};
        $application->helper( $helper => sub { return $fake; } );
    }
    my %switched = (
        gp_permission_gate    => 'gate',
        gp_rate_limiter       => 'limiter',
        gp_security_telemetry => 'telemetry',
        gp_suspension_store   => 'suspensions',
    );
    for my $helper ( sort keys %switched ) {
        my $key = $switched{$helper};
        $application->helper( $helper => sub { return $double{$key}; } );
    }

    my $routes = $application->routes;
    $routes->get('/__test/session/:user_id')->to(
        cb => sub ($controller) {
            $controller->session( user_id => $controller->param('user_id') );
            return $controller->render( json => { ok => 1 } );
        }
    );
    $routes->get('/__test/csrf')->to(
        cb => sub ($controller) {
            return $controller->render(
                json => { csrf_token => $controller->csrf_token } );
        }
    );

    return;
}

1;
