package main;

use strict;
use warnings;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::CommandIdempotency;
use GPForum::Test::ForumWebServices;
use GPForum::Test::IdentitySecurityAudit;
use GPForum::Test::IdentityStore;

our $VERSION = '0.001';

const my $HTTP_ACCEPTED     => 202;
const my $HTTP_BAD_REQUEST  => 400;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_FOUND        => 302;
const my $HTTP_OK           => 200;
const my $HTTP_UNAUTHORIZED => 401;
const my $FORM_SNIPPET      => 800;

my $test = Test::Mojo->new('GPForum');
_install_identity_fakes($test);
_install_forum_fakes($test);

$test->get_ok(q{/});
$test->status_is($HTTP_OK);
$test->element_exists('nav[aria-label="Primary"] a[href="/categories"]');
$test->element_exists('nav[aria-label="Primary"] a[href="/new-thread"]');
$test->element_exists('nav[aria-label="Primary"] a[href="/search"]');
$test->element_exists('nav[aria-label="Identity"] a[href="/register"]');
$test->element_exists('nav[aria-label="Identity"] a[href="/login"]');

$test->get_ok('/bookmarks');
$test->status_is($HTTP_UNAUTHORIZED);
$test->content_like(qr/authentication [ ] required/msx);
$test->element_exists('a[href="/login"]');
$test->element_exists('a[href="/register"]');

$test->get_ok('/register');
$test->status_is($HTTP_OK);
my $register_token      = _csrf_token($test);
my $register_command_id = _command_id($test);
$test->post_ok(
    '/register' => form => {
        command_id   => $register_command_id,
        csrf_token   => $register_token,
        username     => 'MVP_User',
        display_name => 'MVP User',
        email        => 'mvp@example.test',
        password     => 'correct horse battery staple',
    }
);
$test->status_is($HTTP_ACCEPTED);
$test->text_is( 'h1' => 'Registration accepted' );
$test->element_exists(
    'nav[aria-label="Registration next steps"] a[href="/login"]');

$test->get_ok('/login');
$test->status_is($HTTP_OK);
my $login_token      = _csrf_token($test);
my $login_command_id = _command_id($test);
$test->post_ok(
    '/login' => form => {
        command_id => $login_command_id,
        csrf_token => $login_token,
        identifier => 'mvp_user',
        password   => 'correct horse battery staple',
    }
);
$test->status_is($HTTP_ACCEPTED);
$test->text_is( 'h1' => 'Login request accepted' );
$test->content_like(qr/You [ ] are [ ] signed [ ] in/msx);
$test->element_exists('form[action="/logout"]');
$test->element_exists('form[action="/logout"] input[name="command_id"]');
$test->element_exists('nav[aria-label="Primary"] a[href="/bookmarks"]');
$test->element_exists(
    'nav[aria-label="Login next steps"] a[href="/new-thread"]');

$test->get_ok('/new-thread?category_id=category-1');
$test->status_is($HTTP_OK);
$test->element_exists('option[value="category-1"][selected]');
my $thread_token      = _csrf_token($test);
my $thread_command_id = _command_id( $test, '/threads' );

$test->post_ok(
    '/threads' => form => {
        csrf_token  => $thread_token,
        category_id => 'category-1',
        command_id  => $thread_command_id,
        title       => q{},
        body_source => q{},
        visibility  => 'public',
    }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->content_like(qr/Please [ ] fix [ ] the [ ] highlighted [ ] fields/msx);
$test->content_like(qr/title [ ] is [ ] required/msx);
$test->content_like(qr/body_source [ ] is [ ] required/msx);
$test->element_exists('option[value="category-1"][selected]');

$thread_token      = _csrf_token($test);
$thread_command_id = _command_id( $test, '/threads' );
$test->post_ok(
    '/threads' => form => {
        csrf_token  => $thread_token,
        category_id => 'category-1',
        command_id  => $thread_command_id,
        title       => 'A real MVP thread',
        body_source => 'Opening post for the MVP flow',
        visibility  => 'public',
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/t/thread-created\z}msx );

$test->get_ok('/t/thread-1');
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'Welcome' );
$test->element_exists('form[action="/t/thread-1/replies"]');
$test->element_exists('form[action="/t/thread-1/bookmark"]');
$test->element_exists('form[action="/t/thread-1/subscribe"]');
my $thread_page_token    = _csrf_token($test);
my $reply_command_id     = _command_id( $test, '/t/thread-1/replies' );
my $bookmark_command_id  = _command_id( $test, '/t/thread-1/bookmark' );
my $subscribe_command_id = _command_id( $test, '/t/thread-1/subscribe' );

$test->post_ok(
    '/t/thread-1/replies' => form => {
        csrf_token  => $thread_page_token,
        body_source => 'A real reply',
        command_id  => $reply_command_id,
        visibility  => 'public',
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/t/thread-1\#post-post-created\z}msx );

$test->post_ok(
    '/t/thread-1/bookmark' => form => {
        command_id => $bookmark_command_id,
        csrf_token => $thread_page_token,
        note       => 'Return to this discussion',
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/t/thread-1\z}msx );

$test->post_ok(
    '/t/thread-1/subscribe' => form => {
        command_id => $subscribe_command_id,
        csrf_token => $thread_page_token,
        preference => 'all',
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/t/thread-1\z}msx );

$test->get_ok('/search?q=welcome');
$test->status_is($HTTP_OK);
$test->element_exists('ol[aria-label="Search results"] a[href="/t/thread-1"]');

$test->get_ok('/bookmarks');
$test->status_is($HTTP_OK);
$test->element_exists('section[aria-labelledby="bookmarks-heading"]');
$test->element_exists('a[href="/t/thread-1"]');
my $logout_token      = _csrf_token($test);
my $logout_command_id = _command_id( $test, '/logout' );

$test->post_ok(
    '/logout' => form => {
        command_id => $logout_command_id,
        csrf_token => $logout_token,
    }
);
$test->status_is($HTTP_ACCEPTED);
$test->text_is( 'h1' => 'Logout request accepted' );
$test->content_like(qr/You [ ] are [ ] signed [ ] out/msx);
$test->element_exists('nav[aria-label="Logout next steps"] a[href="/login"]');

$test->post_ok('/threads');
$test->status_is($HTTP_FORBIDDEN);
$test->content_like(qr/Bad [ ] CSRF [ ] token/msx);

done_testing;

sub _install_identity_fakes {
    my ($test_object) = @_;

    $test_object->app->helper(
        gp_identity_store => sub {
            return GPForum::Test::IdentityStore->new;
        }
    );
    $test_object->app->helper(
        gp_profile_reader => sub {
            return GPForum::Test::IdentityStore->new;
        }
    );
    $test_object->app->helper(
        gp_identity_security_audit => sub {
            return GPForum::Test::IdentitySecurityAudit->new;
        }
    );

    return;
}

sub _install_forum_fakes {
    my ($test_object) = @_;

    my $services = GPForum::Test::ForumWebServices->new;
    for my $helper (
        qw(
        gp_category_reader gp_home_page_reader gp_thread_reader
        gp_thread_detail_reader gp_thread_composer gp_thread_store
        gp_post_composer gp_post_store gp_post_position gp_thread_read_state
        gp_mention_store gp_mention_reader gp_bookmark_store
        gp_subscription_store gp_notification_dispatcher gp_report_store
        gp_search_service gp_rate_limiter gp_suspension_store
        gp_attachment_store
        )
      )
    {
        $test_object->app->helper( $helper => sub { return $services; } );
    }
    $test_object->app->helper(
        gp_feed_reader => sub {
            return GPForum::Test::ForumWebServices->new( mode => 'feed' );
        }
    );
    $test_object->app->helper(
        gp_command_idempotency => sub {
            return GPForum::Test::CommandIdempotency->new;
        }
    );

    return;
}

sub _csrf_token {
    my ($test_object) = @_;

    my $body = $test_object->tx->res->body;
    my ($token) = $body =~ /name="csrf_token" [^>]+ value="([^"]+)"/msx;

    return $token;
}

sub _command_id {
    my ( $test_object, $form_action ) = @_;

    my $body = $test_object->tx->res->body;
    if ($form_action) {
        return _command_id_in_form( $body, $form_action );
    }

    my ($command_id) = $body =~ /name="command_id" [^>]+ value="([^"]+)"/msx;

    return $command_id;
}

sub _command_id_in_form {
    my ( $body, $form_action ) = @_;

    my $quote  = q{"};
    my $marker = 'action=' . $quote . $form_action . $quote;
    my $start  = index $body, $marker;
    if ( $start < 0 ) {
        return;
    }

    my $chunk        = substr $body, $start, $FORM_SNIPPET;
    my ($command_id) = $chunk =~ /name="command_id" [^>]+ value="([^"]+)"/msx;

    return $command_id;
}

1;
