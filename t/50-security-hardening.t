package main;

use strict;
use warnings;

use Const::Fast;
use Mojo::File qw(path);
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Identity::SecurityAudit;
use GPForum::Test::AdminWebServices;
use GPForum::Test::AllowPermissionGate;
use GPForum::Test::DenyPermissionGate;
use GPForum::Test::FixedClock;
use GPForum::Test::ForumWebServices;
use GPForum::Test::Id;
use GPForum::Test::IdentitySecurityAudit;
use GPForum::Test::Schema;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;

subtest 'identity audit hashes sensitive request fields' => sub {
    my $schema = GPForum::Test::Schema->new;
    my $audit  = GPForum::Service::Identity::SecurityAudit->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
        schema     => $schema,
    );

    $audit->record_login_request(
        {
            identifier      => 'giacomo@example.test',
            outcome         => 'accepted',
            request_address => '198.51.100.10',
        }
    );

    my $row = $schema->created_for('AuditLog')->[0];
    is( $row->{action},
        'identity.login.requested', 'login request audit action is explicit' );
    ok(
        $row->{metadata}{identifier_hash},
        'login audit stores an identifier hash'
    );
    isnt( $row->{metadata}{identifier_hash},
        'giacomo@example.test', 'login audit does not store raw identifier' );
    ok(
        $row->{metadata}{request_address_hash},
        'login audit stores a request address hash'
    );
    isnt( $row->{metadata}{request_address_hash},
        '198.51.100.10', 'login audit does not store raw request address' );
};

subtest 'server-rendered POST forms include CSRF fields' => sub {
    for my $template ( _template_files() ) {
        my $content = path($template)->slurp;
        my @forms =
          $content =~ m{(<form \s+ [^>]* method="post" .*? </form>)}gmsx;
        for my $form (@forms) {
            like( $form, qr/csrf_field/msx,
                "$template POST form includes CSRF" );
        }
    }
};

subtest 'POST routes reject missing CSRF before protected work' => sub {
    my $test = _security_test_app();

    for my $path ( _csrf_post_paths() ) {
        $test->post_ok(
            $path => { Accept => 'application/json' } => form => {} );
        $test->status_is( $HTTP_FORBIDDEN, "$path rejects missing CSRF" );
    }
};

subtest
  'authenticated-only POST routes reject anonymous valid-CSRF requests' => sub {
    my $test  = _security_test_app();
    my $token = _csrf_token($test);

    for my $path ( _authenticated_post_paths() ) {
        $test->post_ok(
            $path => { Accept => 'application/json' } => form => {
                csrf_token => $token,
            }
        );
        $test->status_is( $HTTP_UNAUTHORIZED,
            "$path rejects anonymous valid-CSRF request" );
    }
  };

subtest 'normal users cannot cross admin or moderation boundaries' => sub {
    my $test = _security_test_app();
    _install_test_session_route($test);
    $test->get_ok('/__test/session/user-normal');
    $test->status_is($HTTP_OK);

    my $token = _csrf_token($test);
    $test->app->helper(
        gp_permission_gate => sub {
            return GPForum::Test::DenyPermissionGate->new;
        }
    );

    $test->get_ok( '/admin' => { Accept => 'application/json' } );
    $test->status_is( $HTTP_FORBIDDEN, 'normal user cannot view admin' );
    $test->post_ok(
        '/admin/roles' => { Accept => 'application/json' } => form => {
            csrf_token => $token,
            name       => 'forbidden',
        }
    );
    $test->status_is( $HTTP_FORBIDDEN, 'normal user cannot write admin' );
    $test->get_ok( '/moderation/reports' => { Accept => 'application/json' } );
    $test->status_is( $HTTP_FORBIDDEN,
        'normal user cannot view moderation queue' );
    $test->post_ok(
        '/moderation/posts/post-1/hide' => { Accept => 'application/json' } =>
          form => {
            csrf_token => $token,
            reason     => 'forbidden',
          }
    );
    $test->status_is( $HTTP_FORBIDDEN, 'normal user cannot moderate content' );
};

subtest 'expired sessions do not authorize protected routes' => sub {
    my $test = _security_test_app();
    _install_test_session_route($test);

    $test->get_ok('/__test/expired-session/user-normal');
    $test->status_is($HTTP_OK);
    $test->get_ok( '/notifications' => { Accept => 'application/json' } );
    $test->status_is( $HTTP_UNAUTHORIZED,
        'expired session cannot read notification inbox' );
};

subtest 'moderator identity without permission remains forbidden' => sub {
    my $test = _security_test_app();
    _install_test_session_route($test);
    $test->get_ok('/__test/session/moderator-1');
    $test->status_is($HTTP_OK);

    my $token = _csrf_token($test);
    $test->app->helper(
        gp_permission_gate => sub {
            return GPForum::Test::DenyPermissionGate->new;
        }
    );

    $test->get_ok(
        '/moderation/suspensions' => { Accept => 'application/json' } );
    $test->status_is( $HTTP_FORBIDDEN,
        'moderator label alone cannot view suspension queue' );
    $test->post_ok(
        '/moderation/users/user-2/suspend' =>
          { Accept => 'application/json' } => form => {
            csrf_token => $token,
            reason     => 'forbidden',
          }
    );
    $test->status_is( $HTTP_FORBIDDEN,
        'moderator label alone cannot suspend users' );
};

subtest 'public discovery surfaces do not leak restricted fixture content' =>
  sub {
    my $test = _security_test_app();

    $test->get_ok('/feed.atom');
    $test->status_is($HTTP_OK);
    $test->content_unlike(
        qr/private [ ] text [ ] must [ ] not [ ] leak/msx,
        'Atom feed excludes hidden thread excerpt'
    );

    $test->get_ok('/sitemap.xml');
    $test->status_is($HTTP_OK);
    $test->content_unlike( qr/thread-hidden/msx,
        'sitemap excludes hidden thread URL' );

    $test->get_ok( '/search?q=hidden' => { Accept => 'application/json' } );
    $test->status_is($HTTP_OK);
    $test->content_unlike(
        qr/private [ ] text [ ] must [ ] not [ ] leak/msx,
        'search response excludes restricted fixture excerpt'
    );
  };

done_testing();

sub _security_test_app {
    my $test = Test::Mojo->new('GPForum');
    _install_forum_fakes($test);
    _install_admin_fakes($test);
    $test->app->helper(
        gp_identity_security_audit => sub {
            return GPForum::Test::IdentitySecurityAudit->new;
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
        gp_rate_limiter gp_suspension_store gp_moderation_action_store
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

    my $route = $test->app->routes->get('/__test/session/:user_id');
    $route->to(
        cb => sub {
            my ($controller) = @_;

            $controller->session( user_id => $controller->param('user_id') );
            return $controller->render( json => { ok => 1 } );
        }
    );
    my $expired = $test->app->routes->get('/__test/expired-session/:user_id');
    $expired->to(
        cb => sub {
            my ($controller) = @_;

            $controller->session( user_id => $controller->param('user_id') );
            $controller->session( expires => 1 );
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

sub _template_files {
    my $root = path('templates');

    return grep { $_ !~ m{/layouts/}msx } sort $root->list_tree->grep(
        sub {
            return $_->to_string =~ /[.] html [.] ep \z/msx ? 1 : 0;
        }
    )->map('to_string')->each;
}

sub _csrf_post_paths {
    return ( '/register', '/login', '/logout', _authenticated_post_paths(), );
}

sub _authenticated_post_paths {
    return (
        '/threads',
        '/t/thread-1/replies',
        '/t/thread-1/read',
        '/t/thread-1/bookmark',
        '/t/thread-1/bookmark/remove',
        '/t/thread-1/subscribe',
        '/t/thread-1/subscribe/mute',
        '/t/thread-1/subscribe/remove',
        '/t/thread-1/report',
        '/p/post-1/report',
        '/notifications/notification-1/read',
        '/admin/roles',
        '/admin/permissions',
        '/admin/roles/role-1/permissions',
        '/admin/users/user-2/roles',
        '/admin/role-bindings/binding-1/revoke',
        '/moderation/reports/report-1/assign',
        '/moderation/reports/report-1/resolve',
        '/moderation/posts/post-1/hide',
        '/moderation/posts/post-1/restore',
        '/moderation/threads/thread-1/lock',
        '/moderation/threads/thread-1/unlock',
        '/moderation/actions/action-post-hide/reverse',
        '/moderation/users/user-2/suspend',
        '/moderation/suspensions/suspension-1/revoke',
    );
}

1;
