# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::AdminWebServices;
use GPForum::Test::AllowLimiter;
use GPForum::Test::AllowPermissionGate;
use GPForum::Test::CommandIdempotency;
use GPForum::Test::FailingAdminAuditReview;
use GPForum::Test::ForumWebServices;
use GPForum::Test::PrivacyWebServices;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_SERVER_ERROR => 500;
const my $JSON              => { Accept => 'application/json' };

# Each page read sits in a try whose catch logs one line and answers the
# page's own failure: a 500 with the error payload, or the page with the
# part that could not be read marked unavailable. A catch that fell through,
# or let the error out to Mojolicious's exception page, fails here.

my $test   = Test::Mojo->new('GPForum');
my $app    = $test->app;
my @logged = _capture_log($app);
_install_fakes($app);
$test->get_ok('/__test/session/admin-1')->status_is($HTTP_OK);

subtest 'an admin page whose read dies answers 500 and logs it' => sub {
    my @cases = (
        [ '/admin',            gp_admin_console_reader      => 'dashboard' ],
        [ '/admin/roles',      gp_role_catalog              => 'roles' ],
        [ '/admin/categories', gp_category_store            => 'categories' ],
        [ '/admin/users',      gp_admin_console_reader      => 'users' ],
        [ '/admin/jobs',       gp_admin_console_reader      => 'jobs' ],
        [ '/admin/status',     gp_admin_console_reader      => 'status' ],
        [ '/admin/settings',   gp_admin_settings            => 'settings' ],
        [ '/admin/users/user-1/roles', gp_permission_review => 'user roles' ],
    );
    for my $case (@cases) {
        my ( $path, $helper, $name ) = @{$case};
        _with_dead_helper(
            $helper,
            sub {
                _failed_page_ok( $path, "admin $name failed: $helper is down" );
            }
        );
    }

    $app->helper(
        gp_admin_audit_review => sub {
            return GPForum::Test::FailingAdminAuditReview->new;
        }
    );
    _failed_page_ok( '/admin/audit',
        'admin audit failed: audit page read failed' );
    $app->helper(
        gp_admin_audit_review => sub {
            return GPForum::Test::AdminWebServices->new;
        }
    );
};

subtest 'an admin section that cannot be read leaves the page up' => sub {
    _with_dead_helper(
        gp_admin_maintenance => sub {
            $test->get_ok( '/admin/jobs' => $JSON )->status_is($HTTP_OK);
            $test->json_is( '/maintenance/search' => { unavailable => 1 } );
            _logged_ok(
                'warn: admin search status failed: gp_admin_maintenance is down'
            );
        }
    );
    _with_dead_helper(
        gp_admin_diagnostics => sub {
            $test->get_ok( '/admin/settings' => $JSON )->status_is($HTTP_OK);
            $test->json_is( '/diagnostics_unavailable' => 1 );
            _logged_ok( 'warn: admin diagnostics overview failed: '
                  . 'gp_admin_diagnostics is down' );
        }
    );
};

subtest 'a moderation queue whose read dies answers 500 and logs it' => sub {
    _with_dead_helper(
        gp_report_store => sub {
            _failed_page_ok( '/moderation/reports',
                'moderation report queue failed: gp_report_store is down' );
        }
    );
    for my $case (
        [ '/moderation/actions',     'action history' ],
        [ '/moderation/suspensions', 'suspensions' ],
      )
    {
        my ( $path, $name ) = @{$case};
        _with_dead_helper(
            gp_moderation_review_reader => sub {
                _failed_page_ok( $path,
                        "moderation $name failed: gp_moderation_review_reader "
                      . 'is down' );
            }
        );
    }
};

subtest 'a privacy page whose read dies answers 500 and logs it' => sub {
    for my $case (
        [ '/privacy',       'privacy dashboard failed' ],
        [ '/admin/privacy', 'privacy review failed' ],
      )
    {
        my ( $path, $line ) = @{$case};
        _with_dead_helper(
            gp_data_rights_review => sub {
                _failed_page_ok( $path,
                    "$line: gp_data_rights_review is down" );
            }
        );
    }
};

subtest 'a notification list whose read dies answers 500' => sub {
    for my $case (
        [ '/notifications', 'gp_notification_dispatcher' ],
        [ '/mentions',      'gp_mention_reader' ],
      )
    {
        my ( $path, $helper ) = @{$case};
        _with_dead_helper(
            $helper => sub {
                $test->get_ok( $path => $JSON )->status_is($HTTP_SERVER_ERROR);
                _system_failure_body_ok();
            }
        );
    }
};

subtest 'a home page whose read dies answers its own 500' => sub {
    _with_dead_helper(
        gp_home_page_reader => sub {
            $test->get_ok( q{/} => $JSON )->status_is($HTTP_SERVER_ERROR);
            $test->json_is(
                q{} => { error => 'home_unavailable', status => 'fail' } );
            _logged_ok(
                'error: home page read failed: gp_home_page_reader is down');
        }
    );
};

subtest 'a thread whose attachments cannot be listed still shows' => sub {
    _with_dead_helper(
        gp_attachment_store => sub {
            $test->get_ok( '/t/thread-1' => $JSON )->status_is($HTTP_OK);
            $test->json_is( '/thread/thread_id' => 'thread-1' );
            _logged_ok(
                'warn: attachment listing degraded: gp_attachment_store is down'
            );
        }
    );
};

done_testing();

sub _failed_page_ok ( $path, $line ) {
    $test->get_ok( $path => $JSON )->status_is( $HTTP_SERVER_ERROR, $path );
    _system_failure_body_ok();
    _logged_ok("error: $line");

    return;
}

sub _system_failure_body_ok {
    $test->json_is(
        q{} => {
            error  => 'internal error',
            status => 'error',
            title  => 'Internal error',
        },
        'the error payload, not the exception page'
    );

    return;
}

# The line the catch logged, without the croak's " at FILE line N.".
sub _logged_ok ($expected) {
    my @lines = map { s/[ ]at[ ]\S+[ ]line[ ]\d+[.]?\s*\z//msxr } @logged;
    ok( ( grep { $_ eq $expected } @lines ), "logged '$expected'" )
      or diag explain \@lines;
    @logged = ();

    return;
}

# The helper dies when asked for its service, as the database going away
# would make the service's first query die, for the one call.
sub _with_dead_helper ( $helper, $check ) {
    my $live = $app->renderer->get_helper($helper);
    $app->helper( $helper => sub { croak "$helper is down" } );
    $check->();
    $app->helper( $helper => $live );

    return;
}

sub _capture_log ($application) {
    my $log = $application->log;
    $log->level('trace');
    $log->unsubscribe('message');
    $log->on(
        message => sub ( $, $level, @lines ) {
            push @logged, join q{ }, "$level:", @lines;
        }
    );

    return ();
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
              gp_moderation_action_store gp_suspension_store
              gp_moderation_review_reader gp_attachment_store
              gp_home_page_reader)
        ),
        gp_data_rights_review  => $privacy,
        gp_command_idempotency => GPForum::Test::CommandIdempotency->new,
        gp_permission_gate     => GPForum::Test::AllowPermissionGate->new,
        gp_rate_limiter        => GPForum::Test::AllowLimiter->new,
    );
    for my $helper ( sort keys %fakes ) {
        my $fake = $fakes{$helper};
        $application->helper( $helper => sub { return $fake; } );
    }
    $application->routes->get('/__test/session/:user_id')->to(
        cb => sub ($controller) {
            $controller->session( user_id => $controller->param('user_id') );
            return $controller->render( json => { ok => 1 } );
        }
    );

    return;
}

1;
