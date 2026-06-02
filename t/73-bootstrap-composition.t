package main;

use strict;
use warnings;

use Mojo::File qw(path);
use Test::Mojo;
use Test::More;

use lib 'lib';

our $VERSION = '0.001';

my $test = Test::Mojo->new('GPForum');
my $app  = $test->app;

for my $route_name ( _route_names() ) {
    ok( $app->routes->find($route_name), "route $route_name is registered" );
}

for my $helper_name ( _helper_names() ) {
    ok(
        $app->renderer->get_helper($helper_name),
        "helper $helper_name resolves on controller"
    );
}

my $registered_helpers = _registered_bootstrap_helpers();
is_deeply( _duplicate_helper_names($registered_helpers),
    [], 'bootstrap modules register every helper name exactly once' );
is_deeply( _missing_registered_helpers($registered_helpers),
    [], 'expected helper list is complete against bootstrap registrations' );
is_deeply( _unregistered_controller_helpers($registered_helpers),
    [], 'controller helper calls are registered by bootstrap modules' );

$app->routes->get('/__composition/i18n')->to(
    cb => sub {
        my ($controller) = @_;

        return $controller->render( text => $controller->t('nav.search') );
    }
);
$app->routes->get('/__composition/security')->to(
    cb => sub {
        my ($controller) = @_;

        return $controller->render( text => 'ok' );
    }
);

$test->get_ok( '/__composition/i18n' => { 'Accept-Language' => 'it' } )
  ->status_is(200)
  ->header_is( 'Content-Language' => 'it' )
  ->content_is('Cerca');

$test->get_ok('/__composition/security')
  ->status_is(200)
  ->header_is( 'X-Content-Type-Options' => 'nosniff' )
  ->header_is( 'X-Frame-Options'        => 'DENY' )
  ->header_like( 'Content-Security-Policy' => qr/default-src 'self'/ms )
  ->content_is('ok');

done_testing();

sub _route_names {
    return qw(
      admin_audit
      admin_dashboard
      admin_jobs
      admin_permission_create
      admin_role_bind
      admin_role_binding_revoke
      admin_role_create
      admin_role_permission_attach
      admin_roles
      admin_status
      admin_user_roles
      admin_users
      attachment_download
      bookmarks
      categories
      category
      feed
      forum_search
      health
      health_live
      health_ready
      home
      locale_update
      login
      login_submit
      mentions
      metrics
      moderation_action_reverse
      moderation_actions
      moderation_post_hide
      moderation_post_restore
      moderation_report_assign
      moderation_report_release
      moderation_report_resolve
      moderation_reports
      moderation_suspension_revoke
      moderation_suspensions
      moderation_thread_lock
      moderation_thread_unlock
      moderation_user_suspend
      new_thread
      notification_read
      notifications
      post_attachment_upload
      post_report
      privacy_dashboard
      privacy_deletion_approve
      privacy_deletion_hold
      privacy_deletion_request
      privacy_erasure_run
      privacy_export_request
      privacy_review
      profile
      profile_report
      public_feed
      realtime
      register
      register_submit
      reply_create
      robots
      search_autocomplete
      settings
      settings_update
      sitemap
      thread
      thread_bookmark
      thread_bookmark_remove
      thread_canonical
      thread_create
      thread_mark_read
      thread_report
      thread_subscribe
      thread_subscription_mute
      thread_unsubscribe
      theme_update
    );
}

sub _helper_names {
    return qw(
      gp_admin_audit_review
      gp_admin_console_reader
      gp_admin_view_model
      gp_attachment_view_model
      gp_attachment_delivery
      gp_attachment_storage
      gp_attachment_store
      gp_attachment_upload_pipeline
      gp_bookmark_store
      gp_community_view_model
      gp_canonical_url
      gp_category_reader
      gp_clock
      gp_command_idempotency
      gp_config
      gp_data_rights_review
      gp_db_query_stats
      gp_deletion_workflow
      gp_discovery_view_model
      gp_export_bundle_builder
      gp_feed_builder
      gp_feed_reader
      gp_forum_view_model
      gp_home_page_reader
      gp_id
      gp_identity_security_audit
      gp_identity_store
      gp_identity_view_model
      gp_local_cache
      gp_media_processor
      gp_mention_reader
      gp_mention_store
      gp_metadata_builder
      gp_metrics_snapshot
      gp_moderation_action_store
      gp_moderation_review_reader
      gp_moderation_view_model
      gp_notification_dispatcher
      gp_notification_preference_store
      gp_notification_renderer
      gp_notifications_view_model
      gp_outbox_dispatcher
      gp_outbox_transport
      gp_password
      gp_permission_gate
      gp_permission_review
      gp_post_composer
      gp_post_position
      gp_post_reader
      gp_post_store
      gp_posting_workflow
      gp_profile_reader
      gp_privacy_view_model
      gp_public_http_cache
      gp_rate_limiter
      gp_readiness
      gp_realtime_listener_supervisor
      gp_realtime_pg_listener
      gp_realtime_pg_notifier
      gp_realtime_hub
      gp_registration
      gp_report_store
      gp_retention_hold_store
      gp_robots_policy
      gp_role_binding_store
      gp_role_catalog
      gp_runtime
      gp_runtime_policy
      gp_schema
      gp_search_service
      gp_security_telemetry
      gp_session_token
      gp_sitemap_builder
      gp_subscription_store
      gp_suspension_store
      gp_thread_composer
      gp_thread_detail_reader
      gp_thread_read_state
      gp_thread_reader
      gp_thread_store
      gp_worker_registrar
      i18n
      i18n_service
      l
      t
      tc
      ui_action
      ui_actions
      ui_attr
      ui_badge
      ui_breadcrumbs
      ui_date
      ui_datetime
      ui_direction
      ui_flash_messages
      ui_label
      ui_locale
      ui_locale_metadata
      ui_locale_options
      ui_next_page
      ui_number
      ui_presenter
      ui_render_policy
      ui_return_to
      ui_theme
      ui_theme_color
      ui_theme_color_scheme
      ui_theme_metadata
      ui_theme_options
      ui_theme_registry
      ui_time
      ui_tone
      ui_trusted_html
      ui_typography_class
    );
}

sub _registered_bootstrap_helpers {
    my %registered;

    for my $file (
        path('lib/GPForum/Bootstrap')->list->grep(qr/[.]pm\z/msx)->each )
    {
        my $source = $file->slurp;
        while ( $source =~ /->helper \s* \( \s* ([A-Za-z0-9_]+)/gmsx ) {
            push @{ $registered{$1} }, "$file";
        }
    }

    return \%registered;
}

sub _duplicate_helper_names {
    my ($registered) = @_;

    my @duplicates = map { "$_:" . join q{,}, @{ $registered->{$_} } }
      grep { @{ $registered->{$_} } > 1 } sort keys %{$registered};

    return \@duplicates;
}

sub _missing_registered_helpers {
    my ($registered) = @_;

    my %expected   = map  { $_ => 1 } _helper_names();
    my @missing    = grep { !$registered->{$_} } sort keys %expected;
    my @unexpected = grep { !$expected{$_} } sort keys %{$registered};

    return [ @missing, map { "unexpected:$_" } @unexpected ];
}

sub _unregistered_controller_helpers {
    my ($registered) = @_;

    my %used;
    for my $file (
        path('lib/GPForum/Controller')->list->grep(qr/[.]pm\z/msx)->each )
    {
        my $source = $file->slurp;
        while ( $source =~
            /->((?:gp|ui)_[A-Za-z0-9_]+|i18n_service|i18n|tc|t|l)\b/gmsx )
        {
            $used{$1} = 1;
        }
    }

    my @missing = grep { !$registered->{$_} } sort keys %used;

    return \@missing;
}

1;
