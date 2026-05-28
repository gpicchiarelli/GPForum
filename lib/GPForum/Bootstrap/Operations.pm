package GPForum::Bootstrap::Operations;

use strict;
use warnings;

use English qw(-no_match_vars);

use GPForum::Log;
use GPForum::Schema;
use GPForum::Service::Operations::DbQueryStats;
use GPForum::Service::Operations::LocalCache;
use GPForum::Service::Operations::MetricsSnapshot;
use GPForum::Service::Operations::QueryBudget;
use GPForum::Service::Operations::RateLimiter;
use GPForum::Service::Operations::RateLimiter::PostgreSQLStore;
use GPForum::Service::Operations::Readiness;
use GPForum::Service::Operations::SecurityTelemetry;

our $VERSION = '0.001';

sub register {
    my ( undef, %input ) = @_;

    my $application    = $input{application};
    my $config         = $input{config};
    my $runtime        = $input{runtime};
    my $runtime_policy = $input{runtime_policy};

    $application->config( hypnotoad => $runtime_policy->hypnotoad_config );
    $application->config(
        gpforum_runtime_enforcement => $runtime_policy->report );

    _register_runtime_helpers( $application, $config, $runtime,
        $runtime_policy );
    _register_schema_helpers( $application, $config );
    _register_operational_helpers( $application, $config, $runtime,
        $runtime_policy );

    GPForum::Log->configure( $application, $config );
    _configure_db_query_observer( $application, $config );

    return;
}

sub _register_runtime_helpers {
    my ( $application, $config, $runtime, $runtime_policy ) = @_;

    $application->helper( gp_config  => sub { return $config; } );
    $application->helper( gp_runtime => sub { return $runtime; } );
    $application->helper(
        gp_runtime_policy => sub { return $runtime_policy; } );

    return;
}

sub _register_schema_helpers {
    my ( $application, $config ) = @_;

    my $db_query_stats = GPForum::Service::Operations::DbQueryStats->new;
    $application->helper(
        gp_db_query_stats => sub { return $db_query_stats; } );

    my $schema;
    my $schema_query_stats_attached;
    $application->helper(
        gp_schema => sub {
            $schema ||= GPForum::Schema->connect_from_config($config);
            if ( !$schema_query_stats_attached ) {
                $schema_query_stats_attached =
                  $db_query_stats->attach_to_schema($schema);
            }
            return $schema;
        }
    );

    return;
}

sub _register_operational_helpers {
    my ( $application, $config, $runtime, $runtime_policy ) = @_;

    my $security_telemetry;
    $application->helper(
        gp_security_telemetry => sub {
            $security_telemetry ||=
              GPForum::Service::Operations::SecurityTelemetry->new;
            return $security_telemetry;
        }
    );

    my $local_cache;
    $application->helper(
        gp_local_cache => sub {
            $local_cache ||= GPForum::Service::Operations::LocalCache->new(
                max_entries => $config->local_cache_max_entries,
                namespace   => 'gpforum',
            );
            return $local_cache;
        }
    );

    my $rate_limiter;
    $application->helper(
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

    $application->helper(
        gp_metrics_snapshot => sub {
            my ($controller) = @_;

            my $realtime_supervisor =
              _optional_controller_helper( $controller,
                'gp_realtime_listener_supervisor' );

            return GPForum::Service::Operations::MetricsSnapshot->new(
                runtime             => $runtime,
                runtime_policy      => $runtime_policy,
                schema              => $controller->gp_schema,
                db_query_stats      => $controller->gp_db_query_stats,
                realtime_hub        => $controller->gp_realtime_hub,
                realtime_supervisor => $realtime_supervisor,
                rate_limiter        => $controller->gp_rate_limiter,
                security_telemetry  => $controller->gp_security_telemetry,
                local_caches        => [ $controller->gp_local_cache ],
            );
        }
    );

    $application->helper(
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

    return;
}

sub _optional_controller_helper {
    my ( $controller, $helper ) = @_;

    my $value;
    my $ok = eval {
        $value = $controller->$helper;
        return 1;
    };
    return $value if $ok;

    my $error = $EVAL_ERROR;
    die $error
      if $error !~
      /Can't [ ] locate [ ] object [ ] method [ ] "\Q$helper\E"/msx;

    return;
}

sub _configure_db_query_observer {
    my ( $application, $config ) = @_;

    $application->hook(
        before_dispatch => sub {
            my ($controller) = @_;

            my $stats = $controller->gp_db_query_stats;
            my $token = $stats->start_request(
                {
                    route => $controller->req->url->path->to_string,
                }
            );
            $controller->stash( gp_db_query_stats_token => $token );
        }
    );

    $application->hook(
        after_dispatch => sub {
            my ($controller) = @_;

            my $stats  = $controller->gp_db_query_stats;
            my $token  = $controller->stash('gp_db_query_stats_token');
            my $record = $stats->finish_request(
                $token,
                {
                    route         => _current_route_name($controller),
                    endpoint_name => _query_budget_endpoint($controller),
                    status        => $controller->res->code || 0,
                }
            );
            my $observation =
              _record_query_budget_observation( $stats, $record );
            _add_benchmark_query_headers( $controller, $record, $observation );
            _enforce_query_budget( $config, $record, $observation );
        }
    );

    return;
}

sub _current_route_name {
    my ($controller) = @_;

    return eval { return $controller->current_route; } || 'unknown';
}

sub _query_budget_endpoint {
    my ($controller) = @_;

    my $route        = _current_route_name($controller);
    my %endpoint_for = (
        home                         => 'home',
        categories                   => 'categories',
        category                     => 'category_threads',
        thread                       => 'thread_view',
        thread_canonical             => 'thread_view',
        thread_create                => 'thread_create',
        reply_create                 => 'reply_create',
        thread_report                => 'report_create',
        post_report                  => 'report_create',
        post_attachment_upload       => 'reply_create',
        attachment_download          => 'thread_view',
        profile_report               => 'report_create',
        moderation_reports           => 'moderation_reports',
        moderation_actions           => 'moderation_actions',
        moderation_suspensions       => 'moderation_suspensions',
        moderation_report_assign     => 'report_update',
        moderation_report_release    => 'report_update',
        moderation_report_resolve    => 'report_update',
        moderation_post_hide         => 'moderation_action',
        moderation_post_restore      => 'moderation_action',
        moderation_thread_lock       => 'moderation_action',
        moderation_thread_unlock     => 'moderation_action',
        moderation_action_reverse    => 'moderation_action',
        moderation_user_suspend      => 'user_suspension',
        moderation_suspension_revoke => 'user_suspension',
        forum_search                 => 'search',
        search_autocomplete          => 'search_autocomplete',
        admin_dashboard              => 'admin_dashboard',
        admin_users                  => 'admin_users',
        admin_roles                  => 'admin_roles',
        admin_role_create            => 'admin_role_update',
        admin_permission_create      => 'admin_role_update',
        admin_role_permission_attach => 'admin_role_update',
        admin_user_roles             => 'admin_user_roles',
        admin_role_bind              => 'admin_role_update',
        admin_role_binding_revoke    => 'admin_role_update',
        admin_audit                  => 'admin_audit',
        admin_jobs                   => 'admin_jobs',
        admin_status                 => 'admin_status',
        notifications                => 'notifications',
        notification_read            => 'notifications',
        privacy_review               => 'admin_dashboard',
        privacy_deletion_approve     => 'admin_role_update',
        privacy_deletion_hold        => 'admin_role_update',
        privacy_erasure_run          => 'admin_role_update',
    );

    return $endpoint_for{$route};
}

sub _record_query_budget_observation {
    my ( $stats, $record ) = @_;

    return if !$record || !$record->{endpoint_name};

    my $observation = GPForum::Service::Operations::QueryBudget->new->observe(
        $record->{endpoint_name},
        {
            queries           => $record->{queries},
            transactions      => $record->{transactions},
            duplicate_queries => $record->{duplicate_queries},
        }
    );
    $stats->record_budget_observation( $record->{request_id}, $observation );

    return $observation;
}

sub _add_benchmark_query_headers {
    my ( $controller, $record, $observation ) = @_;

    return if ( $ENV{GPFORUM_BENCHMARK_QUERY_HEADERS} || q{} ) ne '1';
    return if !$record;

    my $headers = $controller->res->headers;
    $headers->header(
        'X-GPForum-DB-Queries' => defined $record->{queries}
        ? $record->{queries}
        : 0
    );
    $headers->header(
        'X-GPForum-DB-Transactions' => defined $record->{transactions}
        ? $record->{transactions}
        : 0
    );
    $headers->header(
        'X-GPForum-DB-Duplicate-Queries' => defined $record->{duplicate_queries}
        ? $record->{duplicate_queries}
        : 0
    );
    $headers->header(
        'X-GPForum-DB-Budget' => $observation
        ? $observation->{status}
        : 'none'
    );
    $headers->header( 'X-GPForum-DB-Budget-Endpoint' => $record->{endpoint_name}
          || 'none' );
    $headers->header(
        'X-GPForum-DB-Budget-Max-Queries' => $observation
          && $observation->{budget}
        ? $observation->{budget}{max_queries}
        : 'none'
    );

    return;
}

sub _enforce_query_budget {
    my ( $config, $record, $observation ) = @_;

    return if ( $ENV{GPFORUM_QUERY_BUDGET_ENFORCE} || q{} ) ne '1';
    return if $config->environment eq 'production';
    return if !$record || !$observation;
    return if ( $observation->{status} || q{} ) ne 'fail';

    die join q{:},
      'query budget exceeded',
      $record->{endpoint_name} || 'unknown',
      join q{,}, @{ $observation->{violations} || [] };
}

1;
