package GPForum;

use strict;
use warnings;

use Mojo::Base 'Mojolicious';

use GPForum::Config;
use GPForum::Log;
use GPForum::OS::RuntimePolicy;
use GPForum::Runtime;
use GPForum::Schema;
use GPForum::Service::Clock;
use GPForum::Service::Community::BookmarkStore;
use GPForum::Service::Community::FeedReader;
use GPForum::Service::Community::MentionReader;
use GPForum::Service::Community::MentionStore;
use GPForum::Service::Discovery::CanonicalUrl;
use GPForum::Service::Discovery::FeedBuilder;
use GPForum::Service::Discovery::MetadataBuilder;
use GPForum::Service::Discovery::RobotsPolicy;
use GPForum::Service::Discovery::SitemapBuilder;
use GPForum::Service::Id;
use GPForum::Service::Forum::CategoryReader;
use GPForum::Service::Forum::HomePageReader;
use GPForum::Service::Forum::PostComposer;
use GPForum::Service::Forum::PostPosition;
use GPForum::Service::Forum::PostReader;
use GPForum::Service::Forum::PostStore;
use GPForum::Service::Forum::ReadState;
use GPForum::Service::Forum::ThreadComposer;
use GPForum::Service::Forum::ThreadDetailReader;
use GPForum::Service::Forum::ThreadReader;
use GPForum::Service::Forum::ThreadStore;
use GPForum::Service::Admin::AuditReview;
use GPForum::Service::Admin::PermissionGate;
use GPForum::Service::Admin::PermissionReview;
use GPForum::Service::Admin::RoleBindingStore;
use GPForum::Service::Admin::RoleCatalog;
use GPForum::Service::Identity::ProfileReader;
use GPForum::Service::Identity::Registration;
use GPForum::Service::Identity::SecurityAudit;
use GPForum::Service::Identity::Store;
use GPForum::Service::Moderation::ActionStore;
use GPForum::Service::Moderation::ReportStore;
use GPForum::Service::Moderation::ReviewReader;
use GPForum::Service::Moderation::SuspensionStore;
use GPForum::Service::Notification::Dispatcher;
use GPForum::Service::Notification::SubscriptionStore;
use GPForum::Service::Operations::LocalCache;
use GPForum::Service::Operations::MetricsSnapshot;
use GPForum::Service::Operations::RateLimiter;
use GPForum::Service::Operations::RateLimiter::PostgreSQLStore;
use GPForum::Service::Operations::Readiness;
use GPForum::Service::Operations::SecurityTelemetry;
use GPForum::Service::Password;
use GPForum::Service::Realtime::Hub;
use GPForum::Service::Search::Searcher;
use GPForum::Service::SessionToken;

our $VERSION = '0.001';

sub startup {
    my ($self) = @_;

    my $config  = GPForum::Config->from_environment;
    my $runtime = GPForum::Runtime->from_config($config);
    my $runtime_policy =
      GPForum::OS::RuntimePolicy->new( config => $config, runtime => $runtime );
    my $root_path = q{/};

    $self->config( hypnotoad => $runtime_policy->hypnotoad_config );
    $self->config( gpforum_runtime_enforcement => $runtime_policy->report );
    $self->secrets( [ $config->session_secret ] );
    $self->mode( $config->environment );
    _configure_browser_security( $self, $config );
    _configure_session_guard($self);

    $self->helper( gp_config         => sub { return $config; } );
    $self->helper( gp_runtime        => sub { return $runtime; } );
    $self->helper( gp_runtime_policy => sub { return $runtime_policy; } );
    my $schema;
    $self->helper(
        gp_schema => sub {
            $schema ||= GPForum::Schema->connect_from_config($config);
            return $schema;
        }
    );
    $self->helper( gp_clock => sub { return GPForum::Service::Clock->new; } );
    $self->helper( gp_id    => sub { return GPForum::Service::Id->new; } );
    $self->helper(
        gp_canonical_url => sub {
            return GPForum::Service::Discovery::CanonicalUrl->new(
                base_url => $config->public_base_url );
        }
    );
    $self->helper(
        gp_feed_builder => sub {
            my ($controller) = @_;

            return GPForum::Service::Discovery::FeedBuilder->new(
                canonical_url => $controller->gp_canonical_url );
        }
    );
    $self->helper(
        gp_metadata_builder => sub {
            my ($controller) = @_;

            return GPForum::Service::Discovery::MetadataBuilder->new(
                canonical_url => $controller->gp_canonical_url );
        }
    );
    $self->helper(
        gp_sitemap_builder => sub {
            my ($controller) = @_;

            return GPForum::Service::Discovery::SitemapBuilder->new(
                canonical_url => $controller->gp_canonical_url );
        }
    );
    $self->helper(
        gp_robots_policy => sub {
            my ($controller) = @_;

            return GPForum::Service::Discovery::RobotsPolicy->new(
                sitemap_url => $controller->gp_canonical_url->base_url
                  . '/sitemap.xml', );
        }
    );
    $self->helper(
        gp_password => sub { return GPForum::Service::Password->new; } );
    $self->helper(
        gp_session_token => sub { return GPForum::Service::SessionToken->new; }
    );
    my $security_telemetry;
    $self->helper(
        gp_security_telemetry => sub {
            $security_telemetry ||=
              GPForum::Service::Operations::SecurityTelemetry->new;
            return $security_telemetry;
        }
    );
    my $local_cache;
    $self->helper(
        gp_local_cache => sub {
            $local_cache ||= GPForum::Service::Operations::LocalCache->new(
                max_entries => $config->local_cache_max_entries,
                namespace   => 'gpforum',
            );
            return $local_cache;
        }
    );
    $self->helper( gp_registration =>
          sub { return GPForum::Service::Identity::Registration->new; } );
    $self->helper(
        gp_identity_security_audit => sub {
            my ($controller) = @_;

            return GPForum::Service::Identity::SecurityAudit->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_identity_store => sub {
            return GPForum::Service::Identity::Store->new(
                schema => shift->gp_schema );
        }
    );
    $self->helper(
        gp_profile_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Identity::ProfileReader->new(
                schema => $controller->gp_schema );
        }
    );
    my $realtime_hub;
    $self->helper(
        gp_realtime_hub => sub {
            $realtime_hub ||= GPForum::Service::Realtime::Hub->new;
            return $realtime_hub;
        }
    );
    my $rate_limiter;
    $self->helper(
        gp_rate_limiter => sub {
            my ($controller) = @_;

            $rate_limiter ||= GPForum::Service::Operations::RateLimiter->new(
                primary_store =>
                  GPForum::Service::Operations::RateLimiter::PostgreSQLStore
                  ->new(
                    schema => $controller->gp_schema
                  ),
                schema             => $controller->gp_schema,
                security_telemetry => $controller->gp_security_telemetry,
            );
            return $rate_limiter;
        }
    );
    $self->helper(
        gp_metrics_snapshot => sub {
            my ($controller) = @_;

            return GPForum::Service::Operations::MetricsSnapshot->new(
                runtime            => $runtime,
                runtime_policy     => $runtime_policy,
                schema             => $controller->gp_schema,
                realtime_hub       => $controller->gp_realtime_hub,
                rate_limiter       => $controller->gp_rate_limiter,
                security_telemetry => $controller->gp_security_telemetry,
                local_caches       => [ $controller->gp_local_cache ],
            );
        }
    );
    $self->helper(
        gp_readiness => sub {
            my ($controller) = @_;

            return GPForum::Service::Operations::Readiness->new(
                environment    => $config->environment,
                runtime        => $runtime,
                runtime_policy => $runtime_policy,
                schema         => $controller->gp_schema,
            );
        }
    );
    $self->helper(
        gp_category_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::CategoryReader->new(
                cache             => $controller->gp_local_cache,
                cache_ttl_seconds => $config->category_cache_ttl_seconds,
                schema            => $controller->gp_schema,
            );
        }
    );
    $self->helper(
        gp_thread_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::ThreadReader->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_home_page_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::HomePageReader->new(
                category_reader => $controller->gp_category_reader,
                thread_reader   => $controller->gp_thread_reader,
            );
        }
    );
    $self->helper(
        gp_post_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::PostReader->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_thread_detail_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::ThreadDetailReader->new(
                schema      => $controller->gp_schema,
                post_reader => $controller->gp_post_reader,
            );
        }
    );
    $self->helper(
        gp_thread_composer => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::ThreadComposer->new(
                id_service => $controller->gp_id );
        }
    );
    $self->helper(
        gp_thread_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::ThreadStore->new(
                schema     => $controller->gp_schema,
                id_service => $controller->gp_id,
            );
        }
    );
    $self->helper(
        gp_post_composer => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::PostComposer->new(
                id_service => $controller->gp_id );
        }
    );
    $self->helper(
        gp_post_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::PostStore->new(
                schema     => $controller->gp_schema,
                id_service => $controller->gp_id,
            );
        }
    );
    $self->helper(
        gp_post_position => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::PostPosition->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_thread_read_state => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::ReadState->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_bookmark_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Community::BookmarkStore->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_feed_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Community::FeedReader->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_mention_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Community::MentionStore->new(
                notification_dispatcher =>
                  $controller->gp_notification_dispatcher,
                schema => $controller->gp_schema,
            );
        }
    );
    $self->helper(
        gp_mention_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Community::MentionReader->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_subscription_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Notification::SubscriptionStore->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_notification_dispatcher => sub {
            my ($controller) = @_;

            return GPForum::Service::Notification::Dispatcher->new(
                schema             => $controller->gp_schema,
                subscription_store => $controller->gp_subscription_store,
            );
        }
    );
    $self->helper(
        gp_report_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Moderation::ReportStore->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_moderation_action_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Moderation::ActionStore->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_suspension_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Moderation::SuspensionStore->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_moderation_review_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Moderation::ReviewReader->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_permission_gate => sub {
            my ($controller) = @_;

            return GPForum::Service::Admin::PermissionGate->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_role_catalog => sub {
            my ($controller) = @_;

            return GPForum::Service::Admin::RoleCatalog->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_role_binding_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Admin::RoleBindingStore->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_permission_review => sub {
            my ($controller) = @_;

            return GPForum::Service::Admin::PermissionReview->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_admin_audit_review => sub {
            my ($controller) = @_;

            return GPForum::Service::Admin::AuditReview->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_search_service => sub {
            my ($controller) = @_;

            return GPForum::Service::Search::Searcher->new(
                schema => $controller->gp_schema );
        }
    );

    GPForum::Log->configure( $self, $config );

    my $routes = $self->routes;

    $routes->get($root_path)->to('Home#show')->name('home');
    $routes->get('/robots.txt')->to('Discovery#robots')->name('robots');
    $routes->get('/sitemap.xml')->to('Discovery#sitemap')->name('sitemap');
    $routes->get('/feed.atom')->to('Discovery#feed')->name('public_feed');
    $routes->get('/health')->to('Health#summary')->name('health');
    $routes->get('/health/live')->to('Health#live')->name('health_live');
    $routes->get('/health/ready')->to('Health#ready')->name('health_ready');
    $routes->get('/metrics')->to('Operations#metrics')->name('metrics');
    $routes->get('/admin')->to('Admin#dashboard')->name('admin_dashboard');
    $routes->get('/admin/roles')->to('Admin#roles')->name('admin_roles');
    $routes->post('/admin/roles')
      ->to('Admin#create_role')
      ->name('admin_role_create');
    $routes->post('/admin/permissions')
      ->to('Admin#create_permission')
      ->name('admin_permission_create');
    $routes->post('/admin/roles/:role_id/permissions')
      ->to('Admin#attach_permission')
      ->name('admin_role_permission_attach');
    $routes->get('/admin/users/:user_id/roles')
      ->to('Admin#user_roles')
      ->name('admin_user_roles');
    $routes->post('/admin/users/:user_id/roles')
      ->to('Admin#bind_role')
      ->name('admin_role_bind');
    $routes->post('/admin/role-bindings/:binding_id/revoke')
      ->to('Admin#revoke_binding')
      ->name('admin_role_binding_revoke');
    $routes->get('/admin/audit')->to('Admin#audit')->name('admin_audit');
    $routes->get('/categories')->to('Forum#categories')->name('categories');
    $routes->get('/c/:category_id')->to('Forum#category')->name('category');
    $routes->get('/t/:thread_id/:slug')
      ->to('Forum#thread')
      ->name('thread_canonical');
    $routes->get('/t/:thread_id')->to('Forum#thread')->name('thread');
    $routes->get('/new-thread')
      ->to('Forum#new_thread_form')
      ->name('new_thread');
    $routes->post('/threads')->to('Forum#create_thread')->name('thread_create');
    $routes->post('/t/:thread_id/replies')
      ->to('Forum#create_reply')
      ->name('reply_create');
    $routes->post('/t/:thread_id/read')
      ->to('Forum#mark_thread_read')
      ->name('thread_mark_read');
    $routes->get('/feed')->to('Forum#feed')->name('feed');
    $routes->get('/bookmarks')->to('Forum#bookmarks')->name('bookmarks');
    $routes->post('/t/:thread_id/bookmark')
      ->to('Forum#create_thread_bookmark')
      ->name('thread_bookmark');
    $routes->post('/t/:thread_id/bookmark/remove')
      ->to('Forum#remove_thread_bookmark')
      ->name('thread_bookmark_remove');
    $routes->post('/t/:thread_id/subscribe')
      ->to('Forum#subscribe_thread')
      ->name('thread_subscribe');
    $routes->post('/t/:thread_id/subscribe/mute')
      ->to('Forum#mute_thread_subscription')
      ->name('thread_subscription_mute');
    $routes->post('/t/:thread_id/subscribe/remove')
      ->to('Forum#unsubscribe_thread')
      ->name('thread_unsubscribe');
    $routes->post('/t/:thread_id/report')
      ->to('Forum#report_thread')
      ->name('thread_report');
    $routes->post('/p/:post_id/report')
      ->to('Forum#report_post')
      ->name('post_report');
    $routes->get('/moderation/reports')
      ->to('Moderation#reports')
      ->name('moderation_reports');
    $routes->get('/moderation/actions')
      ->to('Moderation#actions')
      ->name('moderation_actions');
    $routes->get('/moderation/suspensions')
      ->to('Moderation#suspensions')
      ->name('moderation_suspensions');
    $routes->post('/moderation/reports/:report_id/assign')
      ->to('Moderation#assign_report')
      ->name('moderation_report_assign');
    $routes->post('/moderation/reports/:report_id/resolve')
      ->to('Moderation#resolve_report')
      ->name('moderation_report_resolve');
    $routes->post('/moderation/posts/:post_id/hide')
      ->to('Moderation#hide_post')
      ->name('moderation_post_hide');
    $routes->post('/moderation/posts/:post_id/restore')
      ->to('Moderation#restore_post')
      ->name('moderation_post_restore');
    $routes->post('/moderation/threads/:thread_id/lock')
      ->to('Moderation#lock_thread')
      ->name('moderation_thread_lock');
    $routes->post('/moderation/threads/:thread_id/unlock')
      ->to('Moderation#unlock_thread')
      ->name('moderation_thread_unlock');
    $routes->post('/moderation/actions/:action_id/reverse')
      ->to('Moderation#reverse_action')
      ->name('moderation_action_reverse');
    $routes->post('/moderation/users/:user_id/suspend')
      ->to('Moderation#suspend_user')
      ->name('moderation_user_suspend');
    $routes->post('/moderation/suspensions/:suspension_id/revoke')
      ->to('Moderation#revoke_suspension')
      ->name('moderation_suspension_revoke');
    $routes->get('/notifications')
      ->to('Notifications#inbox')
      ->name('notifications');
    $routes->post('/notifications/:notification_id/read')
      ->to('Notifications#mark_read')
      ->name('notification_read');
    $routes->get('/mentions')->to('Notifications#mentions')->name('mentions');
    $routes->get('/search/autocomplete')
      ->to('Forum#search_autocomplete')
      ->name('search_autocomplete');
    $routes->get('/search')->to('Forum#search')->name('forum_search');
    $routes->get('/register')->to('Identity#register_form')->name('register');
    $routes->post('/register')
      ->to('Identity#register')
      ->name('register_submit');
    $routes->get('/login')->to('Identity#login_form')->name('login');
    $routes->post('/login')->to('Identity#login')->name('login_submit');
    $routes->post('/logout')->to('Identity#logout')->name('logout');
    $routes->get('/u/:username')->to('Identity#profile')->name('profile');
    $routes->websocket('/realtime')->to('Realtime#stream')->name('realtime');

    return;
}

sub _configure_browser_security {
    my ( $application, $config ) = @_;

    $application->sessions->samesite('Lax');
    $application->sessions->secure(
        $config->environment eq 'production' ? 1 : 0 );

    $application->hook(
        after_dispatch => sub {
            my ($controller) = @_;

            _set_browser_security_headers($controller);
        }
    );

    return;
}

sub _configure_session_guard {
    my ($application) = @_;

    $application->hook(
        before_dispatch => sub {
            my ($controller) = @_;

            _expire_stale_session($controller);
            _validate_server_session($controller);
        }
    );

    return;
}

sub _validate_server_session {
    my ($controller) = @_;

    my $session_id = $controller->session('session_id');
    my $user_id    = $controller->session('user_id');
    return if !defined $session_id || !length $session_id;
    return if !defined $user_id    || !length $user_id;

    my $validation = eval {
        return $controller->gp_identity_store->validate_session(
            {
                session_id => $session_id,
                user_id    => $user_id,
            }
        );
    };
    return if $validation && $validation->{ok};

    _clear_web_session($controller);
    $controller->gp_security_telemetry->record(
        'session_invalidated',
        {
            reason => _session_validation_error($validation),
            route  => _current_route_name($controller),
            status => 401,
        }
    );

    return;
}

sub _clear_web_session {
    my ($controller) = @_;

    my $session = $controller->session;
    delete @{$session}
      {qw(user_id session_id login_rotation session_expires_at_epoch)};
    $controller->session( expires => 1 );

    return;
}

sub _session_validation_error {
    my ($validation) = @_;

    return 'validation_failed' if !$validation;
    return $validation->{error} || 'validation_failed';
}

sub _expire_stale_session {
    my ($controller) = @_;

    my $expires_at = $controller->session('session_expires_at_epoch');
    return if !defined $expires_at;
    return if $expires_at > time;

    _clear_web_session($controller);
    $controller->gp_security_telemetry->record(
        'session_expired',
        {
            route  => _current_route_name($controller),
            status => 401,
        }
    );

    return;
}

sub _set_browser_security_headers {
    my ($controller) = @_;

    my $headers = $controller->res->headers;

    $headers->header( 'X-Content-Type-Options' => 'nosniff' );
    $headers->header( 'X-Frame-Options'        => 'DENY' );
    $headers->header( 'Referrer-Policy' => 'strict-origin-when-cross-origin' );
    $headers->header( 'Permissions-Policy' =>
          'camera=(), microphone=(), geolocation=(), payment=()' );
    $headers->content_security_policy(
        join q{; },
        q{default-src 'self'},
        q{base-uri 'self'},
        q{form-action 'self'},
        q{frame-ancestors 'none'},
        q{object-src 'none'},
    );

    return;
}

sub _current_route_name {
    my ($controller) = @_;

    return eval { return $controller->current_route; } || 'unknown';
}

1;

__END__

=head1 NAME

GPForum - Mojolicious application root.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $app = GPForum->new;

=head1 DESCRIPTION

Bootstraps the GPForum web application, helpers, logging, runtime profile, and
the currently traversable forum routes.

=head1 SUBROUTINES/METHODS

=head2 startup

Configures application dependencies and routes.

=head1 DIAGNOSTICS

Startup delegates configuration validation to L<GPForum::Config>.

=head1 CONFIGURATION AND ENVIRONMENT

Reads runtime configuration through L<GPForum::Config>.

=head1 DEPENDENCIES

Uses L<Mojolicious> plus GPForum configuration, logging, runtime, clock, and ID
services.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The application is still an MVP. Some advanced boundaries remain operational
contracts before becoming complete product workflows.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
