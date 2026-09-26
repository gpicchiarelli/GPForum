# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Moderation::ActionStore;
use GPForum::Service::Moderation::ReportStore;
use GPForum::Service::Operations::CommandIdempotency;
use GPForum::Service::Privacy::Workflow;
use GPForum::Test::AdminWebServices;
use GPForum::Test::AllowLimiter;
use GPForum::Test::AllowPermissionGate;
use GPForum::Test::AttachmentWebServices;
use GPForum::Test::CountingWrite;
use GPForum::Test::EngineeringCorrectness::Schema;
use GPForum::Test::FixedClock;
use GPForum::Test::ForumWebServices;
use GPForum::Test::Id;
use GPForum::Test::IdentitySecurityAudit;
use GPForum::Test::IdentityStore;
use GPForum::Test::NotificationPreferenceStore;
use GPForum::Test::PrivacyWebServices;
use GPForum::Test::Schema;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_CREATED      => 201;
const my $HTTP_ACCEPTED     => 202;
const my $HTTP_FOUND        => 302;
const my $ONCE              => 1;
const my $EXPORT_WRITE_ROWS => 2;
const my $PNG_SIGNATURE     => pack 'H*', '89504e470d0a1a0a';

my $test  = Test::Mojo->new('GPForum');
my $forum = _install_forum_fakes($test);
_install_test_session_route($test);

$test->get_ok('/__test/session/user-1');
$test->status_is($HTTP_OK);
_get_json_ok( $test, '/new-thread' );
my $csrf_token = _json_value( $test, 'csrf_token' );

my $reply_form = {
    body_source => 'A reply',
    command_id  => 'reply-lost-response-1',
    csrf_token  => $csrf_token,
    visibility  => 'public',
};
_post_json( $test, '/t/thread-1/replies', $reply_form );
$test->status_is($HTTP_CREATED);
$test->json_is( '/post_id' => 'post-created' );
_post_json( $test, '/t/thread-1/replies', $reply_form );
$test->status_is($HTTP_CREATED);
$test->json_is( '/post_id' => 'post-created' );
is( $forum->{counted}->create_post_calls,
    $ONCE, 'lost reply response does not persist a second post' );

my $thread_form = {
    body_source => 'Opening post',
    category_id => 'category-1',
    command_id  => 'thread-lost-response-1',
    csrf_token  => $csrf_token,
    title       => 'A real thread',
    visibility  => 'public',
};
_post_json( $test, '/threads', $thread_form );
$test->status_is($HTTP_CREATED);
$test->json_is( '/thread_id' => 'thread-created' );
_post_json( $test, '/threads', $thread_form );
$test->status_is($HTTP_CREATED);
$test->json_is( '/thread_id' => 'thread-created' );
is( $forum->{counted}->create_thread_calls,
    $ONCE, 'lost thread response does not persist a second thread' );

my $read_form = {
    command_id         => 'read-lost-response-1',
    csrf_token         => $csrf_token,
    last_read_position => 1,
};
_post_json( $test, '/t/thread-1/read', $read_form );
$test->status_is($HTTP_OK);
$test->json_is( '/read_state/last_read_position' => 1 );
_post_json( $test, '/t/thread-1/read', $read_form );
$test->status_is($HTTP_OK);
$test->json_is( '/read_state/last_read_position' => 1 );
is( scalar @{ $forum->{services}->read_marker_writes },
    $ONCE, 'lost read-marker response does not persist twice' );

my $attachments = _install_attachment_write_fakes($test);
my $upload_form = {
    attachment => {
        content      => $PNG_SIGNATURE,
        content_type => 'image/png',
        filename     => 'photo.png',
    },
    command_id => 'attachment-upload-lost-1',
    csrf_token => $csrf_token,
};
_post_json( $test, '/p/post-1/attachments', $upload_form );
$test->status_is($HTTP_CREATED);
$test->json_is( '/attachment/attachment_id' => 'attachment-1' );
_post_json( $test, '/p/post-1/attachments', $upload_form );
$test->status_is($HTTP_CREATED);
$test->json_is( '/attachment/attachment_id' => 'attachment-1' );
is( _attachment_upload_count($attachments),
    $ONCE, 'lost upload response does not store a second file' );

my $delete_form = {
    command_id => 'attachment-delete-lost-1',
    csrf_token => $csrf_token,
};
_post_json( $test, '/p/post-1/attachments/attachment-1/delete', $delete_form );
$test->status_is($HTTP_OK);
$test->json_is( '/attachment/attachment_id' => 'attachment-1' );
_post_json( $test, '/p/post-1/attachments/attachment-1/delete', $delete_form );
$test->status_is($HTTP_OK);
$test->json_is( '/attachment/attachment_id' => 'attachment-1' );
is( _attachment_delete_count($attachments),
    $ONCE, 'lost delete response does not soft-delete twice' );

my $bookmark_form = {
    command_id => 'bookmark-lost-1',
    csrf_token => $csrf_token,
    note       => 'later',
};
_post_json( $test, '/t/thread-1/bookmark', $bookmark_form );
$test->status_is($HTTP_OK);
$test->json_is( '/bookmark/target_id' => 'thread-1' );
_post_json( $test, '/t/thread-1/bookmark', $bookmark_form );
$test->status_is($HTTP_OK);
$test->json_is( '/bookmark/target_id' => 'thread-1' );
is( _community_count( $forum->{services}, 'bookmark_saves' ),
    $ONCE, 'lost bookmark response does not persist twice' );

my $bookmark_remove_form = {
    command_id => 'bookmark-remove-lost-1',
    csrf_token => $csrf_token,
};
_post_json( $test, '/t/thread-1/bookmark/remove', $bookmark_remove_form );
$test->status_is($HTTP_OK);
_post_json( $test, '/t/thread-1/bookmark/remove', $bookmark_remove_form );
$test->status_is($HTTP_OK);
is( _community_count( $forum->{services}, 'bookmark_removes' ),
    $ONCE, 'lost bookmark-remove response does not persist twice' );

my $subscribe_form = {
    command_id => 'subscribe-lost-1',
    csrf_token => $csrf_token,
    preference => 'all',
};
_post_json( $test, '/t/thread-1/subscribe', $subscribe_form );
$test->status_is($HTTP_OK);
$test->json_is( '/subscription/target_id' => 'thread-1' );
_post_json( $test, '/t/thread-1/subscribe', $subscribe_form );
$test->status_is($HTTP_OK);
$test->json_is( '/subscription/target_id' => 'thread-1' );
is( _community_count( $forum->{services}, 'subscription_saves' ),
    $ONCE, 'lost subscribe response does not persist twice' );

my $mute_form = {
    command_id => 'subscribe-mute-lost-1',
    csrf_token => $csrf_token,
};
_post_json( $test, '/t/thread-1/subscribe/mute', $mute_form );
$test->status_is($HTTP_OK);
_post_json( $test, '/t/thread-1/subscribe/mute', $mute_form );
$test->status_is($HTTP_OK);
is( _community_count( $forum->{services}, 'subscription_mutes' ),
    $ONCE, 'lost mute response does not persist twice' );

my $unsubscribe_form = {
    command_id => 'subscribe-remove-lost-1',
    csrf_token => $csrf_token,
};
_post_json( $test, '/t/thread-1/subscribe/remove', $unsubscribe_form );
$test->status_is($HTTP_OK);
_post_json( $test, '/t/thread-1/subscribe/remove', $unsubscribe_form );
$test->status_is($HTTP_OK);
is( _community_count( $forum->{services}, 'subscription_revokes' ),
    $ONCE, 'lost unsubscribe response does not persist twice' );

my $reports     = _install_report_store($test);
my $report_form = {
    command_id => 'report-lost-response-1',
    csrf_token => $csrf_token,
    details    => 'Thread report',
    reason     => 'spam',
};
_post_json( $test, '/t/thread-1/report', $report_form );
$test->status_is($HTTP_OK);
my $report_payload = $test->tx->res->json;
my $report_id      = $report_payload->{report}{report_id};
ok( $report_id, 'first report commit returns a report id' );
_post_json( $test, '/t/thread-1/report', $report_form );
$test->status_is($HTTP_OK);
$test->json_is( '/report/report_id' => $report_id );
is( scalar @{ $reports->created_for('Report') },
    $ONCE, 'lost report response does not insert a second report' );

my $actions = _install_hide_store($test);
$test->get_ok('/__test/session/moderator-1');
$test->status_is($HTTP_OK);
_get_json_ok( $test, '/moderation/reports' );
my $moderation_csrf = _json_value( $test, 'csrf_token' );
my $hide_form       = {
    command_id => 'hide-lost-response-1',
    csrf_token => $moderation_csrf,
    reason     => 'spam',
};
_post_json( $test, '/moderation/posts/post-1/hide', $hide_form );
$test->status_is($HTTP_OK);
my $action_payload = $test->tx->res->json;
my $action_id      = $action_payload->{action}{moderation_action_id};
ok( $action_id, 'first hide commit returns an action id' );
_post_json( $test, '/moderation/posts/post-1/hide', $hide_form );
$test->status_is($HTTP_OK);
$test->json_is( '/action/moderation_action_id' => $action_id );
is( scalar @{ $actions->created_for('ModerationAction') },
    $ONCE, 'lost hide response does not insert a second action' );

$test->app->helper( gp_report_store => sub { return $forum->{services}; } );
$test->app->helper(
    gp_moderation_action_store => sub { return $forum->{services}; } );
my $assign_form = {
    command_id => 'assign-lost-response-1',
    csrf_token => $moderation_csrf,
};
_post_json( $test, '/moderation/reports/report-1/assign', $assign_form );
$test->status_is($HTTP_OK);
$test->json_is( '/report/assigned_moderator_user_id' => 'moderator-1' );
_post_json( $test, '/moderation/reports/report-1/assign', $assign_form );
$test->status_is($HTTP_OK);
$test->json_is( '/report/assigned_moderator_user_id' => 'moderator-1' );
is( scalar @{ $forum->{services}->report_assigns },
    $ONCE, 'lost assign response does not persist twice' );

my $reverse_form = {
    command_id => 'reverse-lost-response-1',
    csrf_token => $moderation_csrf,
    reason     => 'appeal accepted',
};
_post_json( $test, '/moderation/actions/action-post-hide/reverse',
    $reverse_form );
$test->status_is($HTTP_OK);
$test->json_is( '/action/reversed_by_user_id' => 'moderator-1' );
_post_json( $test, '/moderation/actions/action-post-hide/reverse',
    $reverse_form );
$test->status_is($HTTP_OK);
$test->json_is( '/action/reversed_by_user_id' => 'moderator-1' );
is( scalar @{ $forum->{services}->action_reverses },
    $ONCE, 'lost reverse response does not persist twice' );

my $suspend_form = {
    confirm    => 1,
    command_id => 'suspend-lost-response-1',
    csrf_token => $moderation_csrf,
    reason     => 'abuse campaign',
};
_post_json( $test, '/moderation/users/user-2/suspend', $suspend_form );
$test->status_is($HTTP_OK);
$test->json_is( '/suspension/user_id' => 'user-2' );
_post_json( $test, '/moderation/users/user-2/suspend', $suspend_form );
$test->status_is($HTTP_OK);
$test->json_is( '/suspension/user_id' => 'user-2' );
is( scalar @{ $forum->{services}->suspension_creates },
    $ONCE, 'lost suspend response does not persist twice' );

my $revoke_form = {
    command_id => 'revoke-lost-response-1',
    csrf_token => $moderation_csrf,
    reason     => 'appeal accepted',
};
_post_json( $test, '/moderation/suspensions/suspension-1/revoke',
    $revoke_form );
$test->status_is($HTTP_OK);
$test->json_is( '/suspension/revoked_at' => '2026-05-23T12:00:00Z' );
_post_json( $test, '/moderation/suspensions/suspension-1/revoke',
    $revoke_form );
$test->status_is($HTTP_OK);
$test->json_is( '/suspension/revoked_at' => '2026-05-23T12:00:00Z' );
is( scalar @{ $forum->{services}->suspension_revokes },
    $ONCE, 'lost revoke response does not persist twice' );

my $exports = _install_privacy_fakes($test);
$test->get_ok('/__test/session/user-1');
$test->status_is($HTTP_OK);
_get_json_ok( $test, '/privacy' );
my $privacy_csrf = _json_value( $test, 'csrf_token' );
my $export_form  = {
    command_id => 'export-lost-response-1',
    csrf_token => $privacy_csrf,
};
_post_json( $test, '/privacy/export', $export_form );
$test->status_is($HTTP_OK);
$test->json_is( '/export_request/export_request_id' => 'export-created' );
_post_json( $test, '/privacy/export', $export_form );
$test->status_is($HTTP_OK);
$test->json_is( '/export_request/export_request_id' => 'export-created' );
is( scalar @{ $exports->created_export_requests },
    $EXPORT_WRITE_ROWS, 'lost export response does not create another bundle' );

my $admin = _install_admin_write_fakes($test);
$test->get_ok('/__test/session/admin-1');
$test->status_is($HTTP_OK);
_get_json_ok( $test, '/admin/roles' );
my $admin_csrf = _json_value( $test, 'csrf_token' );
my $role_form  = {
    command_id => 'admin-role-lost-1',
    csrf_token => $admin_csrf,
    name       => 'space_admin',
};
_post_json( $test, '/admin/roles', $role_form );
$test->status_is($HTTP_OK);
$test->json_is( '/role/name' => 'space_admin' );
_post_json( $test, '/admin/roles', $role_form );
$test->status_is($HTTP_OK);
$test->json_is( '/role/name' => 'space_admin' );
is( _admin_count( $admin, 'role_creates' ),
    $ONCE, 'lost role-create response does not persist twice' );

my $category_form = {
    command_id => 'admin-category-lost-1',
    csrf_token => $admin_csrf,
    title      => 'General',
};
_post_json( $test, '/admin/categories', $category_form );
$test->status_is($HTTP_OK);
$test->json_is( '/category/title' => 'General' );
_post_json( $test, '/admin/categories', $category_form );
$test->status_is($HTTP_OK);
$test->json_is( '/category/title' => 'General' );
is( _admin_count( $admin, 'category_creates' ),
    $ONCE, 'lost category-create response does not persist twice' );

my ( $identity, $notification_prefs ) = _install_identity_fakes($test);
$test->get_ok('/password/reset');
$test->status_is($HTTP_OK);
my $reset_form = {
    command_id => _form_value( $test, 'command_id' ),
    csrf_token => _form_value( $test, 'csrf_token' ),
    identifier => 'giacomo@example.test',
};
$test->post_ok( '/password/reset' => form => $reset_form );
$test->status_is($HTTP_ACCEPTED);
$test->post_ok( '/password/reset' => form => $reset_form );
$test->status_is($HTTP_ACCEPTED);
is( _identity_method_count( $identity, 'request_password_reset' ),
    $ONCE, 'lost password-reset response does not issue a second token' );

$test->get_ok('/email/verify');
$test->status_is($HTTP_OK);
my $verify_form = {
    command_id => _form_value( $test, 'command_id' ),
    csrf_token => _form_value( $test, 'csrf_token' ),
    identifier => 'giacomo@example.test',
};
$test->post_ok( '/email/verify/request' => form => $verify_form );
$test->status_is($HTTP_ACCEPTED);
$test->post_ok( '/email/verify/request' => form => $verify_form );
$test->status_is($HTTP_ACCEPTED);
is( _identity_method_count( $identity, 'request_email_verification' ),
    $ONCE, 'lost verification-resend response does not issue a second token' );

my $email_form = {
    command_id => 'email-change-lost-1',
    csrf_token => $verify_form->{csrf_token},
    email      => 'new@example.test',
};
$test->post_ok( '/settings/email' => form => $email_form );
$test->status_is($HTTP_FOUND);
$test->post_ok( '/settings/email' => form => $email_form );
$test->status_is($HTTP_FOUND);
is( _identity_method_count( $identity, 'request_email_change' ),
    $ONCE, 'lost email-change response does not issue a second token' );

my $password_form = {
    command_id       => 'password-change-lost-1',
    csrf_token       => $verify_form->{csrf_token},
    current_password => 'correct horse battery staple',
    new_password     => 'new correct horse battery',
};
$test->post_ok( '/settings/password' => form => $password_form );
$test->status_is($HTTP_FOUND);
$test->post_ok( '/settings/password' => form => $password_form );
$test->status_is($HTTP_FOUND);
is( _identity_method_count( $identity, 'change_password' ),
    $ONCE, 'lost password-change response does not rotate twice' );

my $locale_form = {
    command_id => 'locale-lost-1',
    csrf_token => $verify_form->{csrf_token},
    locale     => 'it',
    return_to  => '/login',
};
$test->post_ok( '/locale' => form => $locale_form );
$test->status_is($HTTP_FOUND);
$test->post_ok( '/locale' => form => $locale_form );
$test->status_is($HTTP_FOUND);
is( _identity_method_count( $identity, 'update_preferred_locale' ),
    $ONCE, 'lost locale response does not persist twice' );

my $theme_form = {
    command_id => 'theme-lost-1',
    csrf_token => $verify_form->{csrf_token},
    return_to  => '/login',
    theme      => 'dark',
};
$test->post_ok( '/theme' => form => $theme_form );
$test->status_is($HTTP_FOUND);
$test->post_ok( '/theme' => form => $theme_form );
$test->status_is($HTTP_FOUND);
is( _identity_method_count( $identity, 'update_preferred_theme' ),
    $ONCE, 'lost theme response does not persist twice' );

my $settings_form = {
    command_id                           => 'settings-lost-1',
    csrf_token                           => $verify_form->{csrf_token},
    locale                               => 'it',
    notification_digest_digest_frequency => 'weekly',
    notification_digest_enabled          => 1,
    notification_email_digest_frequency  => 'daily',
    notification_in_app_digest_frequency => 'immediate',
    notification_in_app_enabled          => 1,
    theme                                => 'dark',
};
$test->post_ok( '/settings' => form => $settings_form );
$test->status_is($HTTP_FOUND);
$test->post_ok( '/settings' => form => $settings_form );
$test->status_is($HTTP_FOUND);
is( _preference_update_count($notification_prefs),
    $ONCE, 'lost settings response does not persist preferences twice' );

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
$test->post_ok( '/register' => form => $register_form );
$test->status_is($HTTP_ACCEPTED);
$test->post_ok( '/register' => form => $register_form );
$test->status_is($HTTP_ACCEPTED);
is( _identity_method_count( $identity, 'create_registration' ),
    $ONCE, 'lost register response does not persist a second pending account' );

$test->get_ok('/login');
$test->status_is($HTTP_OK);
my $login_form = {
    command_id => _form_value( $test, 'command_id' ),
    csrf_token => _form_value( $test, 'csrf_token' ),
    identifier => 'giacomo_forum',
    password   => 'correct horse battery staple',
};
$test->post_ok( '/login' => form => $login_form );
$test->status_is($HTTP_ACCEPTED);
$test->post_ok( '/login' => form => $login_form );
$test->status_is($HTTP_ACCEPTED);

# A login is never replayed from the command log (that handed the stored
# session to anyone with the command id): a retry checks the password again
# and opens its own session.
is( _identity_method_count( $identity, 'authenticate_login' ),
    $ONCE + 1, 'a retried login checks the password again' );

$test->get_ok('/password/reset/reset-token');
$test->status_is($HTTP_OK);
my $reset_complete_form = {
    command_id => _form_value( $test, 'command_id' ),
    csrf_token => _form_value( $test, 'csrf_token' ),
    password   => 'new correct horse battery',
    token      => 'reset-token',
};
$test->post_ok( '/password/reset/complete' => form => $reset_complete_form );
$test->status_is($HTTP_ACCEPTED);
$test->post_ok( '/password/reset/complete' => form => $reset_complete_form );
$test->status_is($HTTP_ACCEPTED);
is( _identity_method_count( $identity, 'reset_password' ),
    $ONCE, 'lost password-reset complete does not consume the token twice' );

$test->get_ok('/email/verify/verify-token');
$test->status_is($HTTP_OK);
my $verify_complete_form = {
    command_id => _form_value( $test, 'command_id' ),
    csrf_token => _form_value( $test, 'csrf_token' ),
    token      => 'verify-token',
};
$test->post_ok( '/email/verify/complete' => form => $verify_complete_form );
$test->status_is($HTTP_ACCEPTED);
$test->post_ok( '/email/verify/complete' => form => $verify_complete_form );
$test->status_is($HTTP_ACCEPTED);
is( _identity_method_count( $identity, 'confirm_email_verification' ),
    $ONCE, 'lost verification complete does not consume the token twice' );

$test->get_ok('/email/confirm/email-token');
$test->status_is($HTTP_OK);
my $email_complete_form = {
    command_id => _form_value( $test, 'command_id' ),
    csrf_token => _form_value( $test, 'csrf_token' ),
    token      => 'email-token',
};
$test->post_ok( '/email/confirm' => form => $email_complete_form );
$test->status_is($HTTP_ACCEPTED);
$test->post_ok( '/email/confirm' => form => $email_complete_form );
$test->status_is($HTTP_ACCEPTED);
is( _identity_method_count( $identity, 'confirm_email_change' ),
    $ONCE, 'lost email-change complete does not consume the token twice' );

$test->get_ok('/login');
$test->status_is($HTTP_OK);
my $logout_form = {
    command_id => _form_value( $test, 'command_id' ),
    csrf_token => _form_value( $test, 'csrf_token' ),
};
my $logout_cookies = _cookie_jar($test);
$test->post_ok( '/logout' => form => $logout_form );
$test->status_is($HTTP_ACCEPTED);
_restore_cookie_jar( $test, $logout_cookies );
$test->post_ok( '/logout' => form => $logout_form );
$test->status_is($HTTP_ACCEPTED);
is( _identity_method_count( $identity, 'revoke_session' ),
    $ONCE, 'lost logout response does not revoke the session twice' );

done_testing();

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

sub _cookie_jar {
    my ($test_object) = @_;

    return [ @{ $test_object->ua->cookie_jar->all } ];
}

sub _restore_cookie_jar {
    my ( $test_object, $cookies ) = @_;

    $test_object->ua->cookie_jar(
        Mojo::UserAgent::CookieJar->new->add( @{$cookies} ) );

    return;
}

sub _preference_update_count {
    my ($store) = @_;

    return scalar @{ $store->updates };
}

sub _identity_method_count {
    my ( $store, $method ) = @_;

    return scalar grep { $_->{method} eq $method } @{ $store->lifecycle_calls };
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
    my $counted  = GPForum::Test::CountingWrite->new( inner => $services );
    my $idempotency =
      GPForum::Service::Operations::CommandIdempotency->new(
        schema => GPForum::Test::Schema->new, );
    for my $helper (
        qw(
        gp_category_reader gp_thread_reader gp_thread_detail_reader
        gp_thread_composer gp_post_reader gp_post_composer
        gp_post_position gp_thread_read_state gp_mention_store
        gp_mention_reader gp_bookmark_store gp_subscription_store
        gp_notification_dispatcher gp_report_store gp_search_service
        gp_rate_limiter gp_suspension_store gp_attachment_store
        )
      )
    {
        $test_object->app->helper( $helper => sub { return $services; } );
    }
    $test_object->app->helper( gp_post_store   => sub { return $counted; } );
    $test_object->app->helper( gp_thread_store => sub { return $counted; } );
    $test_object->app->helper(
        gp_command_idempotency => sub { return $idempotency; } );

    return { counted => $counted, services => $services };
}

sub _install_attachment_write_fakes {
    my ($test_object) = @_;

    my $services = GPForum::Test::AttachmentWebServices->new;
    $test_object->app->helper(
        gp_attachment_delivery => sub { return $services; } );
    $test_object->app->helper(
        gp_attachment_upload_pipeline => sub { return $services; } );
    $test_object->app->helper( gp_post_reader => sub { return $services; } );
    $test_object->app->helper(
        gp_attachment_store => sub { return $services; } );

    return $services;
}

sub _attachment_upload_count {
    my ($store) = @_;

    return scalar @{ $store->upload_calls };
}

sub _admin_count {
    my ( $store, $method ) = @_;

    return scalar @{ $store->$method };
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

sub _community_count {
    my ( $store, $method ) = @_;

    return scalar @{ $store->$method };
}

sub _attachment_delete_count {
    my ($store) = @_;

    return scalar @{ $store->delete_calls };
}

sub _install_report_store {
    my ($test_object) = @_;

    my $schema = GPForum::Test::EngineeringCorrectness::Schema->new;
    my $store  = GPForum::Service::Moderation::ReportStore->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
        schema     => $schema,
    );
    $test_object->app->helper( gp_report_store => sub { return $store; } );

    return $schema;
}

sub _install_hide_store {
    my ($test_object) = @_;

    my $schema = GPForum::Test::EngineeringCorrectness::Schema->new;
    $schema->resultset('Post')->create(
        {
            hidden_at        => undef,
            moderation_state => 'visible',
            post_id          => 'post-1',
        }
    );
    my $store = GPForum::Service::Moderation::ActionStore->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
        schema     => $schema,
    );
    my $fakes = GPForum::Test::ForumWebServices->new;
    $test_object->app->helper(
        gp_moderation_action_store => sub { return $store; } );
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

    return $schema;
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
        export_builder    => $services,
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

    return $services;
}

sub _install_identity_fakes {
    my ($test_object) = @_;

    my $store       = GPForum::Test::IdentityStore->new;
    my $preferences = GPForum::Test::NotificationPreferenceStore->new;
    my $idempotency = GPForum::Service::Operations::CommandIdempotency->new(
        schema => GPForum::Test::Schema->new, );
    $test_object->app->helper( gp_identity_store => sub { return $store; } );

    # Without this the sign-in audit reached for the configured database --
    # a developer's own at 127.0.0.1:5432 -- and wrote to it when it was up.
    $test_object->app->helper( gp_identity_security_audit =>
          sub { return GPForum::Test::IdentitySecurityAudit->new; } );
    $test_object->app->helper(
        gp_notification_preference_store => sub { return $preferences; } );
    $test_object->app->helper(
        gp_command_idempotency => sub { return $idempotency; } );
    $test_object->app->helper(
        gp_rate_limiter => sub { return GPForum::Test::AllowLimiter->new; } );

    return ( $store, $preferences );
}

1;
