package GPForum;

use strict;
use warnings;

use Mojo::Base 'Mojolicious';

use GPForum::Bootstrap::Operations;
use GPForum::Bootstrap::UI;
use GPForum::Config;
use GPForum::OS::RuntimePolicy;
use GPForum::Runtime;
use GPForum::Service::Attachment::Delivery;
use GPForum::Service::Attachment::FilesystemStorage;
use GPForum::Service::Attachment::IntentBuilder;
use GPForum::Service::Attachment::MediaProcessor;
use GPForum::Service::Attachment::Store;
use GPForum::Service::Attachment::UploadPipeline;
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
use GPForum::Service::Admin::ConsoleReader;
use GPForum::Service::Admin::PermissionGate;
use GPForum::Service::Admin::PermissionReview;
use GPForum::Service::Admin::RoleBindingStore;
use GPForum::Service::Admin::RoleCatalog;
use GPForum::Service::Identity::ProfileReader;
use GPForum::Service::Identity::Registration;
use GPForum::Service::Identity::SecurityAudit;
use GPForum::Service::Identity::Store;
use GPForum::Service::I18N;
use GPForum::Service::Moderation::ActionStore;
use GPForum::Service::Moderation::ReportStore;
use GPForum::Service::Moderation::ReviewReader;
use GPForum::Service::Moderation::SuspensionStore;
use GPForum::Service::Notification::Dispatcher;
use GPForum::Service::Notification::Renderer;
use GPForum::Service::Notification::SubscriptionStore;
use GPForum::Service::Password;
use GPForum::Service::Portability::ExportBundleBuilder;
use GPForum::Service::Privacy::DataRightsReview;
use GPForum::Service::Privacy::DeletionWorkflow;
use GPForum::Service::Privacy::RetentionHoldStore;
use GPForum::Service::Realtime::Hub;
use GPForum::Service::Search::PermissionEngine;
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

    $self->secrets( [ $config->session_secret ] );
    $self->mode( $config->environment );
    _configure_static_assets($self);
    _configure_browser_security( $self, $config );

    GPForum::Bootstrap::UI->register(
        application => $self,
        i18n        => GPForum::Service::I18N->new(
            default_locale => $config->default_locale,
        )
    );
    GPForum::Bootstrap::Operations->register(
        application    => $self,
        config         => $config,
        runtime        => $runtime,
        runtime_policy => $runtime_policy,
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
    my $attachment_storage;
    $self->helper(
        gp_attachment_storage => sub {
            $attachment_storage ||=
              GPForum::Service::Attachment::FilesystemStorage->new(
                root => 'var/attachments' );
            return $attachment_storage;
        }
    );
    $self->helper(
        gp_attachment_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Attachment::Store->new(
                clock      => $controller->gp_clock,
                id_service => $controller->gp_id,
                schema     => $controller->gp_schema,
            );
        }
    );
    $self->helper(
        gp_attachment_upload_pipeline => sub {
            my ($controller) = @_;

            return GPForum::Service::Attachment::UploadPipeline->new(
                intent_builder =>
                  GPForum::Service::Attachment::IntentBuilder->new(
                    clock      => $controller->gp_clock,
                    id_service => $controller->gp_id,
                  ),
                storage => $controller->gp_attachment_storage,
                store   => $controller->gp_attachment_store,
            );
        }
    );
    $self->helper(
        gp_attachment_delivery => sub {
            my ($controller) = @_;

            return GPForum::Service::Attachment::Delivery->new(
                storage => $controller->gp_attachment_storage,
                store   => $controller->gp_attachment_store,
            );
        }
    );
    $self->helper(
        gp_media_processor => sub {
            my ($controller) = @_;

            return GPForum::Service::Attachment::MediaProcessor->new(
                storage => $controller->gp_attachment_storage,
                store   => $controller->gp_attachment_store,
            );
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
                realtime_hub       => $controller->gp_realtime_hub,
                schema             => $controller->gp_schema,
                subscription_store => $controller->gp_subscription_store,
            );
        }
    );
    $self->helper(
        gp_notification_renderer => sub {
            my ($controller) = @_;

            return GPForum::Service::Notification::Renderer->new(
                i18n => $controller->i18n_service );
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
        gp_admin_console_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Admin::ConsoleReader->new(
                metrics_snapshot => $controller->gp_metrics_snapshot,
                readiness        => $controller->gp_readiness,
                schema           => $controller->gp_schema,
            );
        }
    );
    $self->helper(
        gp_search_service => sub {
            my ($controller) = @_;

            return GPForum::Service::Search::Searcher->new(
                permission_engine =>
                  GPForum::Service::Search::PermissionEngine->new(
                    schema => $controller->gp_schema
                  ),
                schema => $controller->gp_schema,
            );
        }
    );
    $self->helper(
        gp_export_bundle_builder => sub {
            my ($controller) = @_;

            return GPForum::Service::Portability::ExportBundleBuilder->new(
                clock      => $controller->gp_clock,
                id_service => $controller->gp_id,
                schema     => $controller->gp_schema,
            );
        }
    );
    $self->helper(
        gp_deletion_workflow => sub {
            my ($controller) = @_;

            return GPForum::Service::Privacy::DeletionWorkflow->new(
                clock      => $controller->gp_clock,
                id_service => $controller->gp_id,
                schema     => $controller->gp_schema,
            );
        }
    );
    $self->helper(
        gp_data_rights_review => sub {
            my ($controller) = @_;

            return GPForum::Service::Privacy::DataRightsReview->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_retention_hold_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Privacy::RetentionHoldStore->new(
                clock      => $controller->gp_clock,
                id_service => $controller->gp_id,
                schema     => $controller->gp_schema,
            );
        }
    );

    _configure_session_guard($self);

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
    $routes->get('/admin/users')->to('Admin#users')->name('admin_users');
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
    $routes->get('/admin/jobs')->to('Admin#jobs')->name('admin_jobs');
    $routes->get('/admin/status')->to('Admin#status')->name('admin_status');
    $routes->get('/admin/privacy')
      ->to('Privacy#review')
      ->name('privacy_review');
    $routes->post('/admin/privacy/deletions/:request_id/approve')
      ->to('Privacy#approve_deletion')
      ->name('privacy_deletion_approve');
    $routes->post('/admin/privacy/deletions/:request_id/hold')
      ->to('Privacy#hold_deletion')
      ->name('privacy_deletion_hold');
    $routes->post('/admin/privacy/erasure/:job_id/run')
      ->to('Privacy#run_erasure_job')
      ->name('privacy_erasure_run');
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
    $routes->post('/p/:post_id/attachments')
      ->to('Attachments#upload_post')
      ->name('post_attachment_upload');
    $routes->get('/attachments/:attachment_id/download')
      ->to('Attachments#download')
      ->name('attachment_download');
    $routes->post('/u/:username/report')
      ->to('Forum#report_profile')
      ->name('profile_report');
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
    $routes->post('/moderation/reports/:report_id/release')
      ->to('Moderation#release_report')
      ->name('moderation_report_release');
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
    $routes->post('/locale')->to('Identity#set_locale')->name('locale_update');
    $routes->get('/u/:username')->to('Identity#profile')->name('profile');
    $routes->get('/privacy')
      ->to('Privacy#dashboard')
      ->name('privacy_dashboard');
    $routes->post('/privacy/export')
      ->to('Privacy#request_export')
      ->name('privacy_export_request');
    $routes->post('/privacy/deletion')
      ->to('Privacy#request_deletion')
      ->name('privacy_deletion_request');
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

sub _configure_static_assets {
    my ($application) = @_;

    my $paths = $application->static->paths;
    push @{$paths},
      $application->home->rel_file('assets/css')->to_string,
      $application->home->rel_file('assets/img')->to_string;

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
