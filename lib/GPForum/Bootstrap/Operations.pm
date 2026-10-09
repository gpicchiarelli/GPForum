# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Bootstrap::Operations;

use v5.40;

use Const::Fast;
use English qw(-no_match_vars);

use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Infrastructure::Antivirus;
use GPForum::Infrastructure::PgNotifications;
use GPForum::Log;
use GPForum::Schema;
use GPForum::Service::Operations::DbQueryStats;
use GPForum::Service::Operations::CommandIdempotency;
use GPForum::Service::Operations::CacheFactory;
use GPForum::Service::Operations::CacheInvalidationBus;
use GPForum::Service::Operations::MetricsSnapshot;
use GPForum::Service::Operations::MetricsTokens;
use GPForum::Service::Operations::Profile;
use GPForum::Service::Operations::QueryBudget;
use GPForum::Service::Operations::RateLimiter;
use GPForum::Service::Operations::RateLimiter::DegradationPolicy;
use GPForum::Service::Operations::RateLimiter::PostgreSQLStore;
use GPForum::Service::Operations::Readiness;
use GPForum::Service::Operations::ScheduledJobs;
use GPForum::Service::Operations::SecurityTelemetry;
use GPForum::Service::I18N::CliCatalog;
use GPForum::X::Check;

our $VERSION = '0.001';

const my $MAX_REQUEST_ID_LENGTH => 128;
const my $PLAIN_REQUEST_ID      => qr/\A [[:alnum:]_.:-]+ \z/msx;
my $request_sequence = 0;

# The query budget each named route is counted under. A route not named here
# has no budget: its queries are recorded, not judged.
const my %ENDPOINT_FOR => (
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
    moderation_thread_hide       => 'moderation_action',
    moderation_thread_lock       => 'moderation_action',
    moderation_thread_restore    => 'moderation_action',
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
    admin_dead_letter_replay     => 'admin_role_update',
    admin_status                 => 'admin_status',
    notifications                => 'notifications',
    notification_read            => 'notifications',
    metrics                      => 'metrics',
    privacy_review               => 'admin_dashboard',
    privacy_deletion_approve     => 'admin_role_update',
    privacy_deletion_hold        => 'admin_role_update',
    privacy_erasure_run          => 'admin_role_update',
);

sub register ( $, %input ) {
    my $application    = $input{application};
    my $config         = $input{config};
    my $runtime        = $input{runtime};
    my $runtime_policy = $input{runtime_policy};

    $application->config( hypnotoad => $runtime_policy->hypnotoad_config );
    $application->config(
        gpforum_runtime_enforcement => $runtime_policy->report );

    $application->helper( gp_config  => sub { return $config; } );
    $application->helper( gp_runtime => sub { return $runtime; } );
    $application->helper(
        gp_runtime_policy => sub { return $runtime_policy; } );
    _register_schema_helpers( $application, $config );
    _register_operational_helpers( $application, $config, $runtime,
        $runtime_policy );

    GPForum::Log->configure( $application, $config );

    # The metrics tokens follow the environment file the service started
    # with, so a rotation needs no restart (ADR 0124). Whether they do is
    # decided here, once, before Hypnotoad forks its workers.
    GPForum::Service::Operations::MetricsTokens->watch(
        $config,
        parser => 'GPForum::Command::Support::ServiceEnvironment',
        log    => $application->log,
    );
    if ( $runtime_policy->outdated_unit ) {
        $application->log->warn(
            GPForum::Service::I18N::CliCatalog->new->text(
                'runtime.outdated_unit')
        );
    }
    _configure_db_query_observer( $application, $config );

    return;
}

sub _register_schema_helpers ( $application, $config ) {
    my $db_query_stats = GPForum::Service::Operations::DbQueryStats->new(
        connection_actions => $config->database_session_settings );
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

    # One notification queue per handle. The cache invalidation bus and the
    # realtime listener both LISTEN on gp_schema's connection, and each used
    # to read its buffer whole and take the other's notifications.
    my $pg_notifications;
    $application->helper(
        gp_pg_notifications => sub {
            my ($controller) = @_;

            $pg_notifications ||=
              GPForum::Infrastructure::PgNotifications->new(
                schema => $controller->gp_schema );
            return $pg_notifications;
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
            my ($controller) = @_;

            $local_cache ||= _application_cache( $config, $controller );
            return $local_cache;
        }
    );

    my $rate_limiter;
    $application->helper(
        gp_rate_limiter => sub {
            my ($controller) = @_;

            # Development keeps the permissive local-memory fallback; staging
            # and the production profiles fail closed, so a database outage
            # cannot lift the limit.
            $rate_limiter ||= GPForum::Service::Operations::RateLimiter->new(
                degradation_policy =>
                  GPForum::Service::Operations::RateLimiter::DegradationPolicy
                  ->from_config(
                    $config),
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
        gp_command_idempotency => sub {
            my ($controller) = @_;

            return GPForum::Service::Operations::CommandIdempotency->new(
                clock      => $controller->gp_clock,
                id_service => $controller->gp_id,
                schema     => $controller->gp_schema,
            );
        }
    );

    $application->helper(
        gp_metrics_snapshot => sub {
            my ($controller) = @_;

            my $realtime_supervisor =
              _optional_controller_helper( $controller,
                'gp_realtime_listener_supervisor' );

            # Forum registers the dispatcher; its badge counters are the
            # process's, so a fresh one reads what every request counted.
            my $notification_dispatcher =
              _optional_controller_helper( $controller,
                'gp_notification_dispatcher' );

            return GPForum::Service::Operations::MetricsSnapshot->new(
                runtime                 => $runtime,
                runtime_policy          => $runtime_policy,
                schema                  => $controller->gp_schema,
                db_query_stats          => $controller->gp_db_query_stats,
                realtime_hub            => $controller->gp_realtime_hub,
                realtime_supervisor     => $realtime_supervisor,
                notification_dispatcher => $notification_dispatcher,
                rate_limiter            => $controller->gp_rate_limiter,
                security_telemetry      => $controller->gp_security_telemetry,
                local_caches            => [ $controller->gp_local_cache ],
            );
        }
    );

    $application->helper(
        gp_readiness => sub {
            my ($controller) = @_;

            # from_config answers undef when scanning is off.
            return GPForum::Service::Operations::Readiness->new(
                antivirus =>
                  GPForum::Infrastructure::Antivirus->from_config($config),
                cache          => $controller->gp_local_cache,
                config         => $config,
                environment    => $config->environment,
                glifistore_url => $config->glifistore_url,
                runtime        => $runtime,
                runtime_policy => $runtime_policy,
                schema         => $controller->gp_schema,
            );
        }
    );

    $application->helper(
        gp_scheduled_jobs => sub {
            my ($controller) = @_;

            return
              GPForum::Service::Operations::ScheduledJobs->from_controller(
                $controller);
        }
    );

    return;
}

# Every Hypnotoad worker holds its own L1 and TieredCache::get short-circuits
# on it, so without a cross-process channel a moderator's hide stays invisible
# to the other workers until the entry expires. PostgreSQL LISTEN/NOTIFY is the
# channel: no new daemon, and the notification is transactional with the write
# that caused it.
#
# A helper is not a method: $controller->can('gp_schema') is false for every
# helper, and asking it that way left the bus unattached in the application,
# so no invalidation ever crossed workers. The helpers are called instead.
#
# Only a TieredCache has a bus: CacheFactory builds a LocalCache alone when no
# shared cache is configured, and then there is no other worker to tell.
sub _application_cache ( $config, $controller ) {
    my $cache = GPForum::Service::Operations::CacheFactory->build($config);
    if ( !$cache->can('bus') || !$controller ) {
        return $cache;
    }

    my $schema;
    try {
        $schema = $controller->gp_schema;
    }
    catch ($error) {
        $schema = undef;
    };
    if ( !$schema ) {
        return $cache;
    }

    my $notifications =
      _optional_controller_helper( $controller, 'gp_pg_notifications' );
    $cache->bus(
        GPForum::Service::Operations::CacheInvalidationBus->new(
            ( $notifications ? ( notifications => $notifications ) : () ),
            schema => $schema,
        )
    );

    return $cache;
}

# The helper's value in scalar context, or undef when it is not registered. A
# return inside try hands the caller's context to the helper; scalar keeps
# one that returns an empty list from shifting a caller's list of pairs.
sub _optional_controller_helper ( $controller, $helper ) {
    try {
        return scalar $controller->$helper;
    }
    catch ($error) {
        die $error    ## no critic (ErrorHandling::RequireCarping) -- rethrows the caught error as it was raised
          if $error !~
          /Can't [ ] locate [ ] object [ ] method [ ] "\Q$helper\E"/msx;
    };

    return undef;
}

sub _configure_db_query_observer {
    my ( $application, $config ) = @_;

    $application->hook(
        before_dispatch => sub {
            my ($controller) = @_;

            my $request_id = _request_id($controller);
            $controller->stash( gp_request_id => $request_id );
            $controller->res->headers->header( 'X-Request-ID' => $request_id );

            my $stats = $controller->gp_db_query_stats;
            my $path  = $controller->req->url->path;
            my $token = $stats->start_request(
                {
                    correlation_id => $request_id,
                    route          => $path->to_string,
                }
            );
            $controller->stash( gp_db_query_stats_token => $token );
        }
    );

    $application->hook(
        after_dispatch => sub {
            my ($controller) = @_;

            if ( $controller->stash('gp_request_id') ) {
                $controller->res->headers->header(
                    'X-Request-ID' => $controller->stash('gp_request_id') );
            }

            my $route;
            try {
                $route = $controller->current_route;
            }
            catch ($error) {
                $route = undef;
            };
            $route ||= 'unknown';

            my $stats         = $controller->gp_db_query_stats;
            my $token         = $controller->stash('gp_db_query_stats_token');
            my $request_stats = $stats->finish_request(
                $token,
                {
                    route         => $route,
                    endpoint_name => exists $ENDPOINT_FOR{$route}
                    ? $ENDPOINT_FOR{$route}
                    : undef,
                    status => $controller->res->code || 0,
                }
            );
            my $observation;
            if ( $request_stats && $request_stats->{endpoint_name} ) {
                $observation =
                  GPForum::Service::Operations::QueryBudget->new->observe(
                    $request_stats->{endpoint_name},
                    {
                        queries           => $request_stats->{queries},
                        transactions      => $request_stats->{transactions},
                        duplicate_queries =>
                          $request_stats->{duplicate_queries},
                    }
                  );
                $stats->record_budget_observation( $request_stats->{request_id},
                    $observation );
            }
            _add_benchmark_query_headers( $controller, $request_stats,
                $observation );
            _enforce_query_budget( $config, $request_stats, $observation );
        }
    );

    return;
}

# The client's X-Request-ID when it is short and plain; otherwise a uuid
# from the id service, or a process-local sequence when there is none.
sub _request_id ($controller) {
    my $header = $controller->req->headers->header('X-Request-ID') || q{};
    if (   length $header
        && length $header <= $MAX_REQUEST_ID_LENGTH
        && $header =~ $PLAIN_REQUEST_ID )
    {
        return $header;
    }

    my $id_service;
    try {
        $id_service = $controller->gp_id;
    }
    catch ($error) {
        $id_service = undef;
    };
    return $id_service->uuid if $id_service;

    $request_sequence++;

    return join q{-}, 'gpforum', $PROCESS_ID, time, $request_sequence;
}

# Per-request database counts, for script/bench-hypnotoad to read back. Never
# in production: there they would tell every client how the database is
# queried, whatever the environment says.
sub _add_benchmark_query_headers ( $controller, $request_stats, $observation ) {
    return if ( $ENV{GPFORUM_BENCHMARK_QUERY_HEADERS} || q{} ) ne '1';
    return if $controller->gp_config->is_production;
    return if !$request_stats;

    my $headers = $controller->res->headers;
    $headers->header(
        'X-GPForum-DB-Queries' => defined $request_stats->{queries}
        ? $request_stats->{queries}
        : 0
    );
    $headers->header(
        'X-GPForum-DB-Transactions' => defined $request_stats->{transactions}
        ? $request_stats->{transactions}
        : 0
    );
    $headers->header(
        'X-GPForum-DB-Duplicate-Queries' =>
          defined $request_stats->{duplicate_queries}
        ? $request_stats->{duplicate_queries}
        : 0
    );
    $headers->header(
        'X-GPForum-DB-Budget' => $observation
        ? $observation->{status}
        : 'none'
    );
    $headers->header(
             'X-GPForum-DB-Budget-Endpoint' => $request_stats->{endpoint_name}
          || 'none' );
    $headers->header(
        'X-GPForum-DB-Budget-Max-Queries' => $observation
          && $observation->{budget}
        ? $observation->{budget}{max_queries}
        : 'none'
    );

    return;
}

# Every server profile ignores the flag -- production, production-small,
# production-medium and staging -- so a breach there shows in metrics and the
# release gates instead of failing a response. Only the name 'production' used
# to: the sized profiles and staging honoured it.
sub _enforce_query_budget ( $config, $request_stats, $observation ) {
    return if ( $ENV{GPFORUM_QUERY_BUDGET_ENFORCE} || q{} ) ne '1';
    my $profile = GPForum::Service::Operations::Profile->name_for_environment(
        $config->environment );
    return if defined $profile && $profile ne 'development';
    return if !$request_stats || !$observation;
    return if ( $observation->{status} || q{} ) ne 'fail';

    my $breach = join q{:},
      'query budget exceeded',
      $request_stats->{endpoint_name} || 'unknown',
      join q{,}, @{ $observation->{violations} || [] };
    GPForum::X::Check->throw( message => $breach );
}

1;
