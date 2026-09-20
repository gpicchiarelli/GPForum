package main;

use strict;
use warnings;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Operations::CommandIdempotency;
use GPForum::Service::Privacy::Workflow;
use GPForum::Test::AdminWebServices;
use GPForum::Test::AllowLimiter;
use GPForum::Test::AllowPermissionGate;
use GPForum::Test::CommandIdempotency;
use GPForum::Test::ForumWebServices;
use GPForum::Test::IdentityStore;
use GPForum::Test::PrivacyWebServices;
use GPForum::Test::Schema;
use GPForum::Test::UnavailableWrite;

our $VERSION = '0.001';

const my $HTTP_OK              => 200;
const my $HTTP_SERVICE_UNAVAIL => 503;
const my $LEAK_PATTERN         => qr/could [ ] not [ ] connect/msx;

my $test = Test::Mojo->new('GPForum');
_install_forum_fakes($test);
_install_test_session_route($test);

$test->get_ok('/__test/session/user-1');
$test->status_is($HTTP_OK);
_get_json_ok( $test, '/new-thread' );
my $csrf_token = _json_value( $test, 'csrf_token' );

$test->app->helper(
    gp_post_store => sub { return GPForum::Test::UnavailableWrite->new; } );
_post_json(
    $test,
    '/t/thread-1/replies',
    {
        body_source => 'A reply',
        command_id  => 'reply-unavailable-1',
        csrf_token  => $csrf_token,
        visibility  => 'public',
    }
);
_assert_unavailable($test);

$test->app->helper(
    gp_post_store => sub { return GPForum::Test::ForumWebServices->new; } );
$test->app->helper(
    gp_command_idempotency => sub {
        return GPForum::Test::UnavailableWrite->new;
    }
);
_post_json(
    $test,
    '/t/thread-1/replies',
    {
        body_source => 'A reply',
        command_id  => 'reply-unavailable-2',
        csrf_token  => $csrf_token,
        visibility  => 'public',
    }
);
_assert_unavailable($test);

$test->post_ok(
    '/t/thread-1/replies' => form => {
        body_source => 'A reply',
        command_id  => 'reply-unavailable-html',
        csrf_token  => $csrf_token,
        visibility  => 'public',
    }
);
$test->status_is($HTTP_SERVICE_UNAVAIL);
$test->content_unlike($LEAK_PATTERN);

_post_json(
    $test,
    '/p/post-1/attachments',
    {
        command_id => 'attachment-upload-unavailable-1',
        csrf_token => $csrf_token,
    }
);
_assert_unavailable($test);

$test->post_ok(
    '/p/post-1/attachments' => form => {
        command_id => 'attachment-upload-unavailable-html',
        csrf_token => $csrf_token,
    }
);
$test->status_is($HTTP_SERVICE_UNAVAIL);
$test->content_unlike($LEAK_PATTERN);

_post_json(
    $test,
    '/p/post-1/attachments/attachment-1/delete',
    {
        command_id => 'attachment-delete-unavailable-1',
        csrf_token => $csrf_token,
    }
);
_assert_unavailable($test);

$test->post_ok(
    '/p/post-1/attachments/attachment-1/delete' => form => {
        command_id => 'attachment-delete-unavailable-html',
        csrf_token => $csrf_token,
    }
);
$test->status_is($HTTP_SERVICE_UNAVAIL);
$test->content_unlike($LEAK_PATTERN);

_post_json(
    $test,
    '/t/thread-1/bookmark',
    {
        command_id => 'bookmark-unavailable-1',
        csrf_token => $csrf_token,
        note       => 'later',
    }
);
_assert_unavailable($test);

_post_json(
    $test,
    '/t/thread-1/bookmark/remove',
    {
        command_id => 'bookmark-remove-unavailable-1',
        csrf_token => $csrf_token,
    }
);
_assert_unavailable($test);

_post_json(
    $test,
    '/t/thread-1/subscribe',
    {
        command_id => 'subscribe-unavailable-1',
        csrf_token => $csrf_token,
        preference => 'all',
    }
);
_assert_unavailable($test);

_post_json(
    $test,
    '/t/thread-1/subscribe/mute',
    {
        command_id => 'subscribe-mute-unavailable-1',
        csrf_token => $csrf_token,
    }
);
_assert_unavailable($test);

_post_json(
    $test,
    '/t/thread-1/subscribe/remove',
    {
        command_id => 'subscribe-remove-unavailable-1',
        csrf_token => $csrf_token,
    }
);
_assert_unavailable($test);

$test->post_ok(
    '/t/thread-1/bookmark' => form => {
        command_id => 'bookmark-unavailable-html',
        csrf_token => $csrf_token,
        note       => 'later',
    }
);
$test->status_is($HTTP_SERVICE_UNAVAIL);
$test->content_unlike($LEAK_PATTERN);

_post_json(
    $test,
    '/t/thread-1/read',
    {
        command_id         => 'read-unavailable-command-1',
        csrf_token         => $csrf_token,
        last_read_position => 1,
    }
);
_assert_unavailable($test);

_post_json(
    $test,
    '/t/thread-1/report',
    {
        command_id => 'report-unavailable-command-1',
        csrf_token => $csrf_token,
        details    => 'Thread report',
        reason     => 'spam',
    }
);
_assert_unavailable($test);

$test->app->helper(
    gp_command_idempotency => sub {
        return GPForum::Test::CommandIdempotency->new;
    }
);
$test->app->helper(
    gp_thread_read_state => sub {
        return GPForum::Test::UnavailableWrite->new;
    }
);
_post_json(
    $test,
    '/t/thread-1/read',
    {
        command_id         => 'read-unavailable-1',
        csrf_token         => $csrf_token,
        last_read_position => 1,
    }
);
_assert_unavailable($test);

$test->app->helper(
    gp_report_store => sub { return GPForum::Test::UnavailableWrite->new; } );
_post_json(
    $test,
    '/t/thread-1/report',
    {
        command_id => 'report-unavailable-1',
        csrf_token => $csrf_token,
        details    => 'Thread report',
        reason     => 'spam',
    }
);
_assert_unavailable($test);

_install_moderation_fakes($test);
$test->get_ok('/__test/session/moderator-1');
$test->status_is($HTTP_OK);
_get_json_ok( $test, '/moderation/reports' );
my $moderation_csrf = _json_value( $test, 'csrf_token' );
$test->app->helper(
    gp_moderation_action_store => sub {
        return GPForum::Test::UnavailableWrite->new;
    }
);
_post_json(
    $test,
    '/moderation/posts/post-1/hide',
    {
        command_id => 'hide-unavailable-1',
        csrf_token => $moderation_csrf,
        reason     => 'spam',
    }
);
_assert_unavailable($test);

$test->app->helper(
    gp_command_idempotency => sub {
        return GPForum::Test::UnavailableWrite->new;
    }
);
_post_json(
    $test,
    '/moderation/posts/post-1/hide',
    {
        command_id => 'hide-unavailable-command-1',
        csrf_token => $moderation_csrf,
        reason     => 'spam',
    }
);
_assert_unavailable($test);

_post_json(
    $test,
    '/moderation/users/user-2/suspend',
    {
        command_id => 'suspend-unavailable-command-1',
        csrf_token => $moderation_csrf,
        reason     => 'abuse campaign',
    }
);
_assert_unavailable($test);

_post_json(
    $test,
    '/moderation/reports/report-1/assign',
    {
        command_id => 'assign-unavailable-command-1',
        csrf_token => $moderation_csrf,
    }
);
_assert_unavailable($test);

$test->app->helper(
    gp_command_idempotency => sub {
        return GPForum::Test::CommandIdempotency->new;
    }
);
$test->app->helper(
    gp_report_store => sub {
        return GPForum::Test::UnavailableWrite->new;
    }
);
_post_json(
    $test,
    '/moderation/reports/report-1/assign',
    {
        command_id => 'assign-unavailable-1',
        csrf_token => $moderation_csrf,
    }
);
_assert_unavailable($test);

$test->app->helper(
    gp_suspension_store => sub {
        return GPForum::Test::UnavailableWrite->new;
    }
);
_post_json(
    $test,
    '/moderation/users/user-2/suspend',
    {
        command_id => 'suspend-unavailable-1',
        csrf_token => $moderation_csrf,
        reason     => 'abuse campaign',
    }
);
_assert_unavailable($test);

_post_json(
    $test,
    '/moderation/suspensions/suspension-1/revoke',
    {
        command_id => 'revoke-unavailable-1',
        csrf_token => $moderation_csrf,
        reason     => 'appeal accepted',
    }
);
_assert_unavailable($test);

_install_privacy_fakes($test);
$test->get_ok('/__test/session/user-1');
$test->status_is($HTTP_OK);
_get_json_ok( $test, '/privacy' );
my $privacy_csrf = _json_value( $test, 'csrf_token' );
_post_json(
    $test,
    '/privacy/export',
    {
        command_id => 'export-unavailable-1',
        csrf_token => $privacy_csrf,
    }
);
_assert_unavailable($test);

$test->app->helper(
    gp_identity_store => sub {
        return GPForum::Test::IdentityStore->new;
    }
);
$test->app->helper(
    gp_command_idempotency => sub {
        return GPForum::Test::UnavailableWrite->new;
    }
);
$test->get_ok('/password/reset');
$test->status_is($HTTP_OK);
my $reset_form = {
    command_id => _form_value( $test, 'command_id' ),
    csrf_token => _form_value( $test, 'csrf_token' ),
    identifier => 'giacomo@example.test',
};
_post_json( $test, '/password/reset', $reset_form );
_assert_unavailable($test);

$test->post_ok( '/password/reset' => form => $reset_form );
$test->status_is($HTTP_SERVICE_UNAVAIL);
$test->content_unlike($LEAK_PATTERN);

$test->get_ok('/email/verify');
$test->status_is($HTTP_OK);
my $verify_form = {
    command_id => _form_value( $test, 'command_id' ),
    csrf_token => _form_value( $test, 'csrf_token' ),
    identifier => 'giacomo@example.test',
};
_post_json( $test, '/email/verify/request', $verify_form );
_assert_unavailable($test);

$test->post_ok( '/email/verify/request' => form => $verify_form );
$test->status_is($HTTP_SERVICE_UNAVAIL);
$test->content_unlike($LEAK_PATTERN);

_post_json(
    $test,
    '/settings/email',
    {
        command_id => 'email-change-unavailable-1',
        csrf_token => $verify_form->{csrf_token},
        email      => 'new@example.test',
    }
);
_assert_unavailable($test);

my $password_form = {
    command_id       => 'password-change-unavailable-1',
    csrf_token       => $verify_form->{csrf_token},
    current_password => 'correct horse battery staple',
    new_password     => 'new correct horse battery',
};
_post_json( $test, '/settings/password', $password_form );
_assert_unavailable($test);

$test->post_ok( '/settings/password' => form => $password_form );
$test->status_is($HTTP_SERVICE_UNAVAIL);
$test->content_unlike($LEAK_PATTERN);

my $locale_form = {
    command_id => 'locale-unavailable-1',
    csrf_token => $verify_form->{csrf_token},
    locale     => 'it',
    return_to  => '/login',
};
_post_json( $test, '/locale', $locale_form );
_assert_unavailable($test);

$test->post_ok( '/locale' => form => $locale_form );
$test->status_is($HTTP_SERVICE_UNAVAIL);
$test->content_unlike($LEAK_PATTERN);

my $theme_form = {
    command_id => 'theme-unavailable-1',
    csrf_token => $verify_form->{csrf_token},
    return_to  => '/login',
    theme      => 'dark',
};
_post_json( $test, '/theme', $theme_form );
_assert_unavailable($test);

$test->post_ok( '/theme' => form => $theme_form );
$test->status_is($HTTP_SERVICE_UNAVAIL);
$test->content_unlike($LEAK_PATTERN);

my $settings_form = {
    command_id => 'settings-unavailable-1',
    csrf_token => $verify_form->{csrf_token},
    locale     => 'en',
    theme      => 'light',
};
_post_json( $test, '/settings', $settings_form );
_assert_unavailable($test);

$test->post_ok( '/settings' => form => $settings_form );
$test->status_is($HTTP_SERVICE_UNAVAIL);
$test->content_unlike($LEAK_PATTERN);

$test->get_ok('/register');
$test->status_is($HTTP_OK);
my $register_form = {
    command_id   => _form_value( $test, 'command_id' ),
    csrf_token   => _form_value( $test, 'csrf_token' ),
    display_name => 'Giacomo Picchiarelli',
    email        => 'giacomo@example.test',
    password     => 'correct horse battery staple',
    username     => 'giacomo',
};
_post_json( $test, '/register', $register_form );
_assert_unavailable($test);

$test->post_ok( '/register' => form => $register_form );
$test->status_is($HTTP_SERVICE_UNAVAIL);
$test->content_unlike($LEAK_PATTERN);

$test->get_ok('/login');
$test->status_is($HTTP_OK);
my $login_form = {
    command_id => _form_value( $test, 'command_id' ),
    csrf_token => _form_value( $test, 'csrf_token' ),
    identifier => 'giacomo@example.test',
    password   => 'correct horse battery staple',
};
_post_json( $test, '/login', $login_form );
_assert_unavailable($test);

$test->post_ok( '/login' => form => $login_form );
$test->status_is($HTTP_SERVICE_UNAVAIL);
$test->content_unlike($LEAK_PATTERN);

$test->get_ok('/password/reset/reset-token');
$test->status_is($HTTP_OK);
my $reset_complete_form = {
    command_id => _form_value( $test, 'command_id' ),
    csrf_token => _form_value( $test, 'csrf_token' ),
    password   => 'new correct horse battery',
    token      => 'reset-token',
};
_post_json( $test, '/password/reset/complete', $reset_complete_form );
_assert_unavailable($test);

$test->post_ok( '/password/reset/complete' => form => $reset_complete_form );
$test->status_is($HTTP_SERVICE_UNAVAIL);
$test->content_unlike($LEAK_PATTERN);

$test->get_ok('/email/verify/verify-token');
$test->status_is($HTTP_OK);
my $verify_complete_form = {
    command_id => _form_value( $test, 'command_id' ),
    csrf_token => _form_value( $test, 'csrf_token' ),
    token      => 'verify-token',
};
_post_json( $test, '/email/verify/complete', $verify_complete_form );
_assert_unavailable($test);

$test->post_ok( '/email/verify/complete' => form => $verify_complete_form );
$test->status_is($HTTP_SERVICE_UNAVAIL);
$test->content_unlike($LEAK_PATTERN);

$test->get_ok('/email/confirm/email-token');
$test->status_is($HTTP_OK);
my $email_complete_form = {
    command_id => _form_value( $test, 'command_id' ),
    csrf_token => _form_value( $test, 'csrf_token' ),
    token      => 'email-token',
};
_post_json( $test, '/email/confirm', $email_complete_form );
_assert_unavailable($test);

$test->post_ok( '/email/confirm' => form => $email_complete_form );
$test->status_is($HTTP_SERVICE_UNAVAIL);
$test->content_unlike($LEAK_PATTERN);

$test->get_ok('/login');
$test->status_is($HTTP_OK);
my $logout_form = {
    command_id => _form_value( $test, 'command_id' ),
    csrf_token => _form_value( $test, 'csrf_token' ),
};
_post_json( $test, '/logout', $logout_form );
_assert_unavailable($test);

$test->post_ok( '/logout' => form => $logout_form );
$test->status_is($HTTP_SERVICE_UNAVAIL);
$test->content_unlike($LEAK_PATTERN);

_install_admin_write_fakes($test);
$test->get_ok('/__test/session/admin-1');
$test->status_is($HTTP_OK);
_get_json_ok( $test, '/admin/roles' );
my $admin_csrf = _json_value( $test, 'csrf_token' );
_post_json(
    $test,
    '/admin/roles',
    {
        command_id => 'admin-role-unavailable-1',
        csrf_token => $admin_csrf,
        name       => 'space_admin',
    }
);
_assert_unavailable($test);

_post_json(
    $test,
    '/admin/categories',
    {
        command_id => 'admin-category-unavailable-1',
        csrf_token => $admin_csrf,
        title      => 'General',
    }
);
_assert_unavailable($test);

$test->post_ok(
    '/admin/roles' => form => {
        command_id => 'admin-role-unavailable-html',
        csrf_token => $admin_csrf,
        name       => 'space_admin',
    }
);
$test->status_is($HTTP_SERVICE_UNAVAIL);
$test->content_unlike($LEAK_PATTERN);

done_testing();

sub _assert_unavailable {
    my ($test_object) = @_;

    $test_object->status_is($HTTP_SERVICE_UNAVAIL);
    $test_object->json_is( '/status' => 'unavailable' );
    $test_object->json_is( '/error'  => 'service unavailable' );
    $test_object->content_unlike($LEAK_PATTERN);

    return;
}

sub _post_json {
    my ( $test_object, $path, $form ) = @_;

    return $test_object->post_ok(
        $path => { Accept => 'application/json' } => form => $form );
}

sub _get_json_ok {
    my ( $test_object, $path ) = @_;

    return $test_object->get_ok( $path => { Accept => 'application/json' } );
}

sub _json_value {
    my ( $test_object, $key ) = @_;

    return $test_object->tx->res->json->{$key};
}

sub _form_value {
    my ( $test_object, $name ) = @_;

    my $body = $test_object->tx->res->body;
    my ($value) = $body =~ /name="$name" [^>]+ value="([^"]+)"/msx;

    return $value;
}

sub _install_test_session_route {
    my ($test_object) = @_;

    my $route = $test_object->app->routes->get('/__test/session/:user_id');
    $route->to(
        cb => sub {
            my ($controller) = @_;

            $controller->session( user_id => $controller->param('user_id') );
            return $controller->render( json => { ok => 1 } );
        }
    );

    return;
}

sub _install_forum_fakes {
    my ($test_object) = @_;

    my $services = GPForum::Test::ForumWebServices->new;
    for my $helper (
        qw(
        gp_category_reader gp_thread_reader gp_thread_detail_reader
        gp_thread_composer gp_thread_store gp_post_reader gp_post_composer
        gp_post_store gp_post_position gp_thread_read_state gp_mention_store
        gp_mention_reader gp_bookmark_store gp_subscription_store
        gp_notification_dispatcher gp_report_store gp_search_service
        gp_rate_limiter gp_suspension_store gp_attachment_store
        )
      )
    {
        $test_object->app->helper( $helper => sub { return $services; } );
    }
    $test_object->app->helper(
        gp_command_idempotency => sub {
            return GPForum::Test::CommandIdempotency->new;
        }
    );

    return;
}

sub _install_admin_write_fakes {
    my ($test_object) = @_;

    my $services = GPForum::Test::AdminWebServices->new;
    $test_object->app->helper( gp_role_catalog   => sub { return $services; } );
    $test_object->app->helper( gp_category_store => sub { return $services; } );
    $test_object->app->helper(
        gp_role_binding_store => sub { return $services; } );
    $test_object->app->helper(
        gp_permission_review => sub { return $services; } );
    $test_object->app->helper(
        gp_admin_audit_review => sub { return $services; } );
    $test_object->app->helper(
        gp_admin_console_reader => sub { return $services; } );
    $test_object->app->helper(
        gp_permission_gate => sub {
            return GPForum::Test::AllowPermissionGate->new;
        }
    );
    $test_object->app->helper(
        gp_rate_limiter => sub { return GPForum::Test::AllowLimiter->new; } );

    return $services;
}

sub _install_moderation_fakes {
    my ($test_object) = @_;

    my $fakes = GPForum::Test::ForumWebServices->new;
    $test_object->app->helper( gp_report_store => sub { return $fakes; } );
    $test_object->app->helper(
        gp_moderation_action_store => sub { return $fakes; } );
    $test_object->app->helper( gp_suspension_store => sub { return $fakes; } );
    $test_object->app->helper(
        gp_moderation_review_reader => sub { return $fakes; } );
    $test_object->app->helper( gp_rate_limiter => sub { return $fakes; } );
    $test_object->app->helper(
        gp_profile_reader => sub {
            return GPForum::Test::IdentityStore->new;
        }
    );
    $test_object->app->helper(
        gp_permission_gate => sub {
            return GPForum::Test::AllowPermissionGate->new;
        }
    );

    return;
}

sub _install_privacy_fakes {
    my ($test_object) = @_;

    my $services = GPForum::Test::PrivacyWebServices->new;
    my $workflow = GPForum::Service::Privacy::Workflow->new(
        command_idempotency =>
          GPForum::Service::Operations::CommandIdempotency->new(
            schema => GPForum::Test::Schema->new,
          ),
        deletion_workflow => $services,
        export_builder    => GPForum::Test::UnavailableWrite->new,
        hold_store        => $services,
        logger            => $test_object->app->log,
        reviewer          => $services,
    );
    $test_object->app->helper(
        gp_privacy_workflow => sub { return $workflow; } );
    $test_object->app->helper(
        gp_data_rights_review => sub { return $services; } );
    $test_object->app->helper(
        gp_permission_gate => sub {
            return GPForum::Test::AllowPermissionGate->new;
        }
    );
    $test_object->app->helper(
        gp_rate_limiter => sub { return GPForum::Test::AllowLimiter->new; } );

    return;
}

1;
