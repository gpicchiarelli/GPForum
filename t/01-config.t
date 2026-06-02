package main;

use strict;
use warnings;

use Const::Fast;
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Config;
use GPForum::Runtime;

our $VERSION = '0.001';

const my $EXPECTED_TESTS            => 58;
const my $CUSTOM_WEB_PROCESSES      => 8;
const my $CUSTOM_WORKER_PROCESSES   => 3;
const my $CUSTOM_REALTIME_PROCESSES => 2;
const my $CUSTOM_RUNTIME_BACKLOG    => 256;
const my $CUSTOM_RUNTIME_CLIENTS    => 80;
const my $CUSTOM_RUNTIME_REQUESTS   => 120;
const my $CUSTOM_RUNTIME_TIMEOUT    => 20;
const my $CUSTOM_MIN_OS_WORKERS     => 2;
const my $CUSTOM_MAX_OPEN_FDS       => 128;
const my $CUSTOM_CACHE_MAX_ENTRIES  => 64;
const my $CUSTOM_CATEGORY_CACHE_TTL => 45;
const my $CUSTOM_REALTIME_POLL      => 2;
const my $CUSTOM_REALTIME_BACKOFF   => 4;
const my $CUSTOM_REALTIME_HEARTBEAT => 12;
const my $CUSTOM_MINION_PG_URL      => 'postgresql://gpforum@/gpforum_minion';
const my $CUSTOM_METRICS_TOKEN      => 'metrics-secret';
const my $TOO_MANY_PROCESSES        => 513;

plan tests => $EXPECTED_TESTS;

my %environment = (
    GPFORUM_ENV                          => 'test',
    GPFORUM_LOG_LEVEL                    => 'info',
    GPFORUM_DEFAULT_LOCALE               => 'it',
    GPFORUM_DEFAULT_THEME                => 'dark',
    GPFORUM_PUBLIC_BASE_URL              => 'http://example.test',
    GPFORUM_SESSION_SECRET               => 'test-secret',
    GPFORUM_DATABASE_DSN                 => 'dbi:Pg:dbname=gpforum_test',
    GPFORUM_DATABASE_USER                => 'gpforum_test',
    GPFORUM_DATABASE_PASSWORD            => 'database-secret',
    GPFORUM_WEB_PROCESSES                => $CUSTOM_WEB_PROCESSES,
    GPFORUM_WORKER_PROCESSES             => $CUSTOM_WORKER_PROCESSES,
    GPFORUM_REALTIME_PROCESSES           => $CUSTOM_REALTIME_PROCESSES,
    GPFORUM_RUNTIME_LISTEN               => 'http://127.0.0.1:9000',
    GPFORUM_RUNTIME_WORKER_POLICY        => 'configured',
    GPFORUM_RUNTIME_MAX_WEB_PER_CPU      => 3,
    GPFORUM_RUNTIME_BACKLOG              => $CUSTOM_RUNTIME_BACKLOG,
    GPFORUM_RUNTIME_CLIENTS              => $CUSTOM_RUNTIME_CLIENTS,
    GPFORUM_RUNTIME_REQUESTS             => $CUSTOM_RUNTIME_REQUESTS,
    GPFORUM_RUNTIME_KEEP_ALIVE_TIMEOUT   => $CUSTOM_RUNTIME_TIMEOUT,
    GPFORUM_RUNTIME_INACTIVITY_TIMEOUT   => $CUSTOM_RUNTIME_TIMEOUT,
    GPFORUM_RUNTIME_GRACEFUL_TIMEOUT     => $CUSTOM_RUNTIME_TIMEOUT,
    GPFORUM_RUNTIME_PROXY                => 0,
    GPFORUM_RUNTIME_PID_FILE             => '/tmp/gpforum-test.pid',
    GPFORUM_OS_REUSEPORT                 => 'off',
    GPFORUM_OS_SENDFILE                  => 'on',
    GPFORUM_OS_WORKER_PRIORITY           => 'auto',
    GPFORUM_OS_STATIC_XSENDFILE          => 'off',
    GPFORUM_OS_AFFINITY                  => 'manual',
    GPFORUM_OS_MIN_RECOMMENDED_WORKERS   => $CUSTOM_MIN_OS_WORKERS,
    GPFORUM_OS_MAX_OPEN_FILE_DESCRIPTORS => $CUSTOM_MAX_OPEN_FDS,
    GPFORUM_LOCAL_CACHE_MAX_ENTRIES      => $CUSTOM_CACHE_MAX_ENTRIES,
    GPFORUM_CATEGORY_CACHE_TTL_SECONDS   => $CUSTOM_CATEGORY_CACHE_TTL,
    GPFORUM_REALTIME_LISTENER_ENABLED    => 1,
    GPFORUM_REALTIME_LISTENER_POLL_INTERVAL_SECONDS => $CUSTOM_REALTIME_POLL,
    GPFORUM_REALTIME_LISTENER_RECONNECT_BACKOFF_SECONDS =>
      $CUSTOM_REALTIME_BACKOFF,
    GPFORUM_REALTIME_LISTENER_HEARTBEAT_INTERVAL_SECONDS =>
      $CUSTOM_REALTIME_HEARTBEAT,
    GPFORUM_MINION_ENABLED => 1,
    GPFORUM_MINION_PG_URL  => $CUSTOM_MINION_PG_URL,
    GPFORUM_METRICS_TOKEN  => $CUSTOM_METRICS_TOKEN,
);

my $config  = GPForum::Config->from_environment( \%environment );
my $runtime = GPForum::Runtime->from_config($config);

is( $config->environment,    'test', 'environment loads from env' );
is( $config->log_level,      'info', 'log level loads from env' );
is( $config->default_locale, 'it',   'default locale loads from env' );
is( $config->default_theme,  'dark', 'default theme loads from env' );
is( $config->public_base_url, 'http://example.test',
    'public base url loads from env' );
is( $config->database_dsn, 'dbi:Pg:dbname=gpforum_test',
    'database dsn loads from env' );
is( $config->database_user, 'gpforum_test', 'database user loads from env' );
is( $config->database_password,
    'database-secret', 'database password loads from env' );
is( $config->web_processes, $CUSTOM_WEB_PROCESSES,
    'web process count loads from env' );
is( $config->worker_processes, $CUSTOM_WORKER_PROCESSES,
    'worker process count loads from env' );
is( $config->realtime_processes,
    $CUSTOM_REALTIME_PROCESSES, 'realtime process count loads from env' );
is( $runtime->as_hash->{web_processes},
    $CUSTOM_WEB_PROCESSES, 'runtime mirrors web process count' );
is_deeply( $config->runtime_listen_locations,
    ['http://127.0.0.1:9000'], 'runtime listen locations split from env' );
is( $config->runtime_worker_policy,
    'configured', 'runtime worker policy loads from env' );
is( $config->runtime_max_web_per_cpu,
    3, 'runtime max web per CPU loads from env' );
is( $config->runtime_backlog,
    $CUSTOM_RUNTIME_BACKLOG, 'runtime backlog loads from env' );
is( $config->runtime_clients,
    $CUSTOM_RUNTIME_CLIENTS, 'runtime clients load from env' );
is( $config->runtime_requests,
    $CUSTOM_RUNTIME_REQUESTS, 'runtime requests load from env' );
is( $config->runtime_keep_alive,
    $CUSTOM_RUNTIME_TIMEOUT, 'runtime keep-alive timeout loads from env' );
is( $config->runtime_inactivity,
    $CUSTOM_RUNTIME_TIMEOUT, 'runtime inactivity timeout loads from env' );
is( $config->runtime_graceful_timeout,
    $CUSTOM_RUNTIME_TIMEOUT, 'runtime graceful timeout loads from env' );
is( $config->runtime_proxy, 0, 'runtime proxy flag loads from env' );
is( $config->runtime_pid_file, '/tmp/gpforum-test.pid',
    'runtime pid file loads from env' );
is( $config->os_reuseport, 'off', 'OS reuseport flag loads from env' );
is( $config->os_sendfile,  'on',  'OS sendfile flag loads from env' );
is( $config->os_worker_priority,
    'auto', 'OS worker priority flag loads from env' );
is( $config->os_static_xsendfile, 'off', 'OS xsendfile flag loads from env' );
is( $config->os_affinity,         'manual', 'OS affinity flag loads from env' );
is( $config->os_min_recommended_workers,
    $CUSTOM_MIN_OS_WORKERS, 'OS minimum worker threshold loads from env' );
is( $config->os_max_open_file_descriptors,
    $CUSTOM_MAX_OPEN_FDS, 'OS file descriptor threshold loads from env' );
is( $config->local_cache_max_entries,
    $CUSTOM_CACHE_MAX_ENTRIES, 'local cache max entries loads from env' );
is( $config->category_cache_ttl_seconds,
    $CUSTOM_CATEGORY_CACHE_TTL, 'category cache TTL loads from env' );
is( $config->realtime_listener_enabled,
    1, 'realtime listener enabled flag loads from env' );
is( $config->realtime_listener_poll_interval_seconds,
    $CUSTOM_REALTIME_POLL, 'realtime listener poll interval loads from env' );
is( $config->realtime_listener_reconnect_backoff_seconds,
    $CUSTOM_REALTIME_BACKOFF,
    'realtime listener reconnect backoff loads from env' );
is( $config->realtime_listener_heartbeat_interval_seconds,
    $CUSTOM_REALTIME_HEARTBEAT,
    'realtime listener heartbeat interval loads from env' );
is( $config->minion_enabled, 1, 'Minion enabled flag loads from env' );
is( $config->minion_pg_url,
    $CUSTOM_MINION_PG_URL, 'Minion PostgreSQL URL loads from env' );
is( $config->metrics_token,
    $CUSTOM_METRICS_TOKEN, 'metrics token loads from env' );
is( GPForum::Config->new->metrics_token,
    q{}, 'metrics token is optional by default' );
is( $runtime->as_hash->{os_features}{reuseport}{setting},
    'off', 'runtime exposes OS feature settings' );
is( $runtime->as_hash->{os_preflight_settings}{min_recommended_workers},
    $CUSTOM_MIN_OS_WORKERS, 'runtime exposes OS preflight settings' );

my @connect_info = $config->database_connect_info;
is( $connect_info[0], $config->database_dsn,
    'connect info includes database dsn' );

throws_ok(
    sub {
        GPForum::Config->from_environment(
            { GPFORUM_WEB_PROCESSES => 'zero' } );
    },
    qr/\A GPFORUM_WEB_PROCESSES [ ] must [ ] be [ ] an [ ] integer/msx,
    'non-integer process count fails validation',
);

throws_ok(
    sub {
        GPForum::Config->new( os_reuseport => 'maybe' )->validate;
    },
    qr/\A os_reuseport [ ] must [ ] be [ ] auto, [ ] on, [ ] or [ ] off/msx,
    'invalid OS feature flag fails validation',
);

throws_ok(
    sub {
        GPForum::Config->new( runtime_worker_policy => 'mystery' )->validate;
    },
qr/\A runtime_worker_policy [ ] must [ ] be [ ] configured [ ] or [ ] cap-to-cpu/msx,
    'invalid runtime worker policy fails validation',
);

throws_ok(
    sub {
        GPForum::Config->new( default_theme => 'neon' )->validate;
    },
qr/\A default_theme [ ] must [ ] be [ ] default, [ ] dark, [ ] or [ ] high_contrast/msx,
    'invalid default theme fails validation',
);

throws_ok(
    sub {
        GPForum::Config->new( runtime_proxy => 2 )->validate;
    },
    qr/\A runtime_proxy [ ] must [ ] be [ ] 0 [ ] or [ ] 1/msx,
    'runtime proxy must be boolean integer',
);

throws_ok(
    sub {
        GPForum::Config->new( realtime_listener_enabled => 2 )->validate;
    },
    qr/\A realtime_listener_enabled [ ] must [ ] be [ ] 0 [ ] or [ ] 1/msx,
    'realtime listener enabled flag must be boolean integer',
);

throws_ok(
    sub {
        GPForum::Config->new( minion_enabled => 2 )->validate;
    },
    qr/\A minion_enabled [ ] must [ ] be [ ] 0 [ ] or [ ] 1/msx,
    'Minion enabled flag must be boolean integer',
);

throws_ok(
    sub {
        GPForum::Config->new( minion_enabled => 1 )->validate;
    },
    qr/\A minion_pg_url [ ] is [ ] required/msx,
    'Minion enabled requires PostgreSQL URL',
);

throws_ok(
    sub {
        GPForum::Config->from_environment(
            {
                GPFORUM_ENV            => 'production',
                GPFORUM_SESSION_SECRET =>
                  'gpforum-development-secret-change-me',
            },
        );
    },
    qr/\A production [ ] requires [ ] GPFORUM_SESSION_SECRET/msx,
    'production rejects default session secret',
);

throws_ok(
    sub {
        GPForum::Config->new( session_secret => q{} )->validate;
    },
    qr/\A session_secret [ ] is [ ] required/msx,
    'empty session secret fails validation',
);

throws_ok(
    sub {
        GPForum::Config->new( web_processes => 0 )->validate;
    },
    qr/\A web_processes [ ] must [ ] be [ ] >= [ ] 1/msx,
    'minimum process bound is enforced',
);

throws_ok(
    sub {
        GPForum::Config->new( worker_processes => $TOO_MANY_PROCESSES )
          ->validate;
    },
    qr/\A worker_processes [ ] must [ ] be [ ] <= [ ] 512/msx,
    'maximum process bound is enforced',
);

throws_ok(
    sub {
        GPForum::Config->new( os_max_open_file_descriptors => 0 )->validate;
    },
    qr/\A os_max_open_file_descriptors [ ] must [ ] be [ ] >= [ ] 1/msx,
    'OS preflight thresholds require positive values',
);

throws_ok(
    sub {
        GPForum::Config->new( local_cache_max_entries => 0 )->validate;
    },
    qr/\A local_cache_max_entries [ ] must [ ] be [ ] >= [ ] 1/msx,
    'local cache max entries require positive values',
);

throws_ok(
    sub {
        GPForum::Config->new( category_cache_ttl_seconds => 0 )->validate;
    },
    qr/\A category_cache_ttl_seconds [ ] must [ ] be [ ] >= [ ] 1/msx,
    'category cache TTL requires positive values',
);

1;
