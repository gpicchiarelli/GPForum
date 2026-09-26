# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

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

my $session_secret_prefix =
  qr/GPFORUM_SESSION_SECRETS [ ] must [ ] not [ ] include/msx;
my $session_secret_suffix = qr/the [ ] development [ ] default/msx;

const my $EXPECTED_TESTS             => 110;
const my $DEFAULT_LOG_LEVEL          => 'info';
const my $DEFAULT_RUNTIME_LISTEN     => 'http://127.0.0.1:8080';
const my $DEFAULT_RUNTIME_BACKLOG    => 256;
const my $DEFAULT_RUNTIME_CLIENTS    => 250;
const my $DEFAULT_RUNTIME_REQUESTS   => 1_000;
const my $DEFAULT_RUNTIME_KEEPALIVE  => 5;
const my $DEFAULT_RUNTIME_GRACEFUL   => 20;
const my $DEFAULT_RUNTIME_HEARTBEAT  => 5;
const my $DEFAULT_RUNTIME_UPGRADE    => 60;
const my $DEFAULT_MIN_OS_WORKERS     => 2;
const my $DEFAULT_MAX_OPEN_FDS       => 65_536;
const my $DEFAULT_CACHE_MAX_ENTRIES  => 2_048;
const my $DEFAULT_CATEGORY_CACHE_TTL => 60;
const my $CUSTOM_WEB_PROCESSES       => 8;
const my $CUSTOM_WORKER_PROCESSES    => 3;
const my $CUSTOM_MAX_WEB_PER_CPU     => 3;
const my $CONNECT_ATTR_INDEX         => 3;
const my $CUSTOM_REALTIME_PROCESSES  => 2;
const my $CUSTOM_RUNTIME_BACKLOG     => 256;
const my $CUSTOM_RUNTIME_CLIENTS     => 80;
const my $CUSTOM_RUNTIME_REQUESTS    => 120;
const my $CUSTOM_RUNTIME_TIMEOUT     => 20;
const my $CUSTOM_MIN_OS_WORKERS      => 2;
const my $CUSTOM_MAX_OPEN_FDS        => 128;
const my $CUSTOM_CACHE_MAX_ENTRIES   => 64;
const my $CUSTOM_CATEGORY_CACHE_TTL  => 45;
const my $CUSTOM_REALTIME_POLL       => 2;
const my $CUSTOM_REALTIME_BACKOFF    => 4;
const my $CUSTOM_REALTIME_HEARTBEAT  => 12;
const my $CUSTOM_MINION_PG_URL       => 'postgresql://gpforum@/gpforum_minion';
const my $CUSTOM_METRICS_TOKEN       => 'metrics-secret';
const my $CUSTOM_GLIFISTORE_URL      => 'tcp://127.0.0.1:7379';
const my $TOO_MANY_PROCESSES         => 513;
const my $DEFAULT_STATEMENT_TIMEOUT_MS => 15_000;
const my $DEFAULT_IDLE_IN_TXN_MS       => 10_000;
const my $DEFAULT_LOCK_TIMEOUT_MS      => 3_000;
const my $CUSTOM_STATEMENT_TIMEOUT_MS  => 7_000;

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
    GPFORUM_RUNTIME_MAX_WEB_PER_CPU      => $CUSTOM_MAX_WEB_PER_CPU,
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
    GPFORUM_GLIFISTORE_URL => $CUSTOM_GLIFISTORE_URL,
    GPFORUM_MAIL_TRANSPORT => 'smtp',
    GPFORUM_MAIL_FROM      => 'forum@example.test',
    GPFORUM_SMTP_HOST      => 'smtp.example.test',
    GPFORUM_SMTP_PORT      => 2525,
    GPFORUM_SMTP_USERNAME  => 'mailer',
    GPFORUM_SMTP_PASSWORD  => 'mail-secret',
    GPFORUM_SMTP_SSL       => 1,
);

my $config  = GPForum::Config->from_environment( \%environment );
my $runtime = GPForum::Runtime->from_config($config);

is( $config->environment,    'test', 'environment loads from env' );
is( $config->log_level,      'info', 'log level loads from env' );
is( $config->default_locale, 'it',   'default locale loads from env' );
is( $config->default_theme,  'dark', 'default theme loads from env' );
is( $config->public_base_url, 'http://example.test',
    'public base url loads from env' );
is( $config->session_secret, 'test-secret', 'session secret loads from env' );
is_deeply( $config->signing_secrets,
    ['test-secret'], 'signing secrets default to the current session secret' );
is_deeply( $config->previous_session_secrets,
    [], 'previous session secrets default empty' );
is_deeply( $config->previous_metrics_tokens,
    [], 'previous metrics tokens default empty' );
is_deeply( $config->accepted_metrics_tokens,
    [$CUSTOM_METRICS_TOKEN],
    'accepted metrics tokens include the current token' );
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
    $CUSTOM_MAX_WEB_PER_CPU, 'runtime max web per CPU loads from env' );
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
is_deeply(
    GPForum::Config->from_environment(
        { GPFORUM_RUNTIME_TRUSTED_PROXIES => ' 10.0.0.0/8 , 127.0.0.1 ' }
    )->runtime_trusted_proxy_list,
    [ '10.0.0.0/8', '127.0.0.1' ],
    'trusted proxies load from env'
);
throws_ok(
    sub {
        GPForum::Config->new( runtime_trusted_proxies => q{ , } )->validate;
    },
    qr/\A runtime_trusted_proxies [ ] must [ ] name/msx,
    'a proxy that trusts nobody is refused'
);
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
is( $config->glifistore_url,
    $CUSTOM_GLIFISTORE_URL, 'GlifiStore URL loads from env' );
is( $config->mail_transport, 'smtp', 'mail transport loads from env' );
is( $config->mail_from,      'forum@example.test', 'mail from loads from env' );
is( $config->smtp_host,      'smtp.example.test',  'SMTP host loads from env' );
my $default_config = GPForum::Config->new;
is( $default_config->log_level,
    $DEFAULT_LOG_LEVEL, 'log level default is production-oriented' );
is( $default_config->metrics_token,
    q{}, 'metrics token is optional by default' );
is( $default_config->glifistore_url,
    $CUSTOM_GLIFISTORE_URL, 'GlifiStore URL defaults to local L2' );
is( $default_config->mail_transport,
    'test', 'mail transport defaults to the test adapter' );
is( $default_config->mail_from,
    'noreply@localhost', 'mail from defaults to a local sender' );
ok( $default_config->requires_glifistore == 0,
    'development does not require an explicit GlifiStore URL' );
ok(
    GPForum::Config->new( environment => 'production-small' )
      ->requires_glifistore,
    'production-small requires GlifiStore'
);
ok( GPForum::Config->environment_requires_glifistore('staging'),
    'staging requires GlifiStore' );
ok(
    $default_config->requires_secure_transport == 0,
    'development does not require secure transport'
);
ok(
    GPForum::Config->new( environment => 'staging' )->requires_secure_transport,
    'staging requires secure transport'
);
ok(
    GPForum::Config->new( environment => 'production-small' )
      ->requires_secure_transport,
    'production-small requires secure transport'
);
is_deeply( $default_config->runtime_listen_locations,
    [$DEFAULT_RUNTIME_LISTEN],
    'runtime listen default binds to local reverse-proxy backend' );
is( $default_config->runtime_backlog,
    $DEFAULT_RUNTIME_BACKLOG, 'runtime backlog default is production-sized' );
is( $default_config->runtime_clients,
    $DEFAULT_RUNTIME_CLIENTS, 'runtime clients default is production-sized' );
is( $default_config->runtime_requests,
    $DEFAULT_RUNTIME_REQUESTS, 'runtime request recycle default is bounded' );
is( $default_config->runtime_keep_alive,
    $DEFAULT_RUNTIME_KEEPALIVE, 'runtime keep-alive default is conservative' );
is( $default_config->runtime_graceful_timeout,
    $DEFAULT_RUNTIME_GRACEFUL, 'runtime graceful default is production-sized' );
is( $default_config->runtime_heartbeat_interval,
    $DEFAULT_RUNTIME_HEARTBEAT,
    'runtime heartbeat interval default is production-sized' );
is( $default_config->runtime_heartbeat_timeout,
    $DEFAULT_RUNTIME_HEARTBEAT,
    'runtime heartbeat timeout default is production-sized' );
is( $default_config->runtime_upgrade_timeout,
    $DEFAULT_RUNTIME_UPGRADE, 'runtime upgrade default is production-sized' );
is( $default_config->os_min_recommended_workers,
    $DEFAULT_MIN_OS_WORKERS,
    'OS minimum worker default matches small production profile' );
is( $default_config->os_max_open_file_descriptors,
    $DEFAULT_MAX_OPEN_FDS,
    'OS file descriptor default matches production floor' );
is( $default_config->local_cache_max_entries,
    $DEFAULT_CACHE_MAX_ENTRIES, 'local cache default is production-sized' );
is( $default_config->category_cache_ttl_seconds,
    $DEFAULT_CATEGORY_CACHE_TTL,
    'category cache TTL default is production-sized' );
is( $default_config->realtime_listener_enabled,
    1, 'realtime listener is enabled by default' );
is( $runtime->as_hash->{os_features}{reuseport}{setting},
    'off', 'runtime exposes OS feature settings' );
is( $runtime->as_hash->{os_preflight_settings}{min_recommended_workers},
    $CUSTOM_MIN_OS_WORKERS, 'runtime exposes OS preflight settings' );

my @connect_info = $config->database_connect_info;
is( $connect_info[0], $config->database_dsn,
    'connect info includes database dsn' );
is_deeply(
    $connect_info[$CONNECT_ATTR_INDEX]{on_connect_do},
    [
        'SET statement_timeout = ' . $DEFAULT_STATEMENT_TIMEOUT_MS,
        'SET idle_in_transaction_session_timeout = ' . $DEFAULT_IDLE_IN_TXN_MS,
        'SET lock_timeout = ' . $DEFAULT_LOCK_TIMEOUT_MS,
        q{SET application_name = 'gpforum'},

        # UniqueConflict falls back to matching the server's English error
        # text when no SQLSTATE is visible. Under any other lc_messages a real
        # unique violation reads as an unknown error and savepoint recovery
        # rethrows it, so the locale is pinned rather than inherited.
        q{SET lc_messages = 'C'},

        # Search's fuzzy-title arm uses pg_trgm's % operator so it can use the
        # trigram index; % reads this threshold, and without it the default of
        # 0.3 would drop every match between 0.18 and 0.3.
        q{SET pg_trgm.similarity_threshold = 0.18},
    ],
    'connect info sets PostgreSQL session timeouts on connect'
);

my $timeout_config = GPForum::Config->from_environment(
    {
        %environment,
        GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS => $CUSTOM_STATEMENT_TIMEOUT_MS,
    }
);
is( $timeout_config->database_statement_timeout_ms,
    $CUSTOM_STATEMENT_TIMEOUT_MS, 'statement timeout loads from env' );

throws_ok(
    sub {
        GPForum::Config->new( database_statement_timeout_ms => -1 )->validate;
    },
    qr/\A database_statement_timeout_ms [ ] must [ ] be [ ] >= [ ] 0/msx,
    'negative statement timeout fails validation',
);

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
        GPForum::Config->new( glifistore_url => 'redis://localhost' )->validate;
    },
    qr/\A glifistore_url [ ] must [ ] be [ ] tcp/msx,
    'invalid GlifiStore URL fails validation',
);

throws_ok(
    sub {
        GPForum::Config->new(
            environment    => 'production-small',
            glifistore_url => q{},
            session_secret => 'rotated-production-secret',
        )->validate;
    },
    qr/\A glifistore_url [ ] is [ ] required/msx,
    'production-small fails closed without GlifiStore',
);

throws_ok(
    sub {
        GPForum::Config->from_environment(
            {
                GPFORUM_ENV            => 'staging',
                GPFORUM_SESSION_SECRET => 'rotated-staging-secret',
            }
        );
    },
    qr/\A glifistore_url [ ] is [ ] required/msx,
    'staging fails closed when GlifiStore is missing',
);

throws_ok(
    sub {
        GPForum::Config->from_environment(
            {
                GPFORUM_ENV            => 'production',
                GPFORUM_GLIFISTORE_URL => $CUSTOM_GLIFISTORE_URL,
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
        GPForum::Config->from_environment(
            {
                GPFORUM_ENV            => 'staging',
                GPFORUM_GLIFISTORE_URL => $CUSTOM_GLIFISTORE_URL,
                GPFORUM_SESSION_SECRET =>
                  'gpforum-development-secret-change-me',
            },
        );
    },
    qr/\A production [ ] requires [ ] GPFORUM_SESSION_SECRET/msx,
    'staging rejects default session secret',
);

throws_ok(
    sub {
        GPForum::Config->from_environment(
            {
                GPFORUM_ENV            => 'production-medium',
                GPFORUM_GLIFISTORE_URL => $CUSTOM_GLIFISTORE_URL,
                GPFORUM_SESSION_SECRET =>
                  'gpforum-development-secret-change-me',
            },
        );
    },
    qr/\A production [ ] requires [ ] GPFORUM_SESSION_SECRET/msx,
    'production-medium rejects default session secret',
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

is(
    GPForum::Config->from_environment(
        {
            GPFORUM_ENV            => 'production',
            GPFORUM_GLIFISTORE_URL => $CUSTOM_GLIFISTORE_URL,
            GPFORUM_METRICS_TOKEN  => $CUSTOM_METRICS_TOKEN,
            GPFORUM_SESSION_SECRET => 'rotated-production-secret',
        }
    )->mail_transport,
    'sendmail',
    'production defaults to sendmail transport'
);

throws_ok(
    sub {
        GPForum::Config->from_environment(
            {
                GPFORUM_ENV            => 'production',
                GPFORUM_GLIFISTORE_URL => $CUSTOM_GLIFISTORE_URL,
                GPFORUM_SESSION_SECRET => 'rotated-production-secret',
            },
        );
    },
    qr/\A production [ ] requires [ ] GPFORUM_METRICS_TOKEN/msx,
    'production fails closed without a metrics scrape token',
);

throws_ok(
    sub {
        GPForum::Config->from_environment(
            {
                GPFORUM_ENV            => 'staging',
                GPFORUM_GLIFISTORE_URL => $CUSTOM_GLIFISTORE_URL,
                GPFORUM_METRICS_TOKEN  => q{},
                GPFORUM_SESSION_SECRET => 'rotated-staging-secret',
            },
        );
    },
    qr/\A production [ ] requires [ ] GPFORUM_METRICS_TOKEN/msx,
    'staging rejects an empty metrics scrape token',
);

throws_ok(
    sub {
        GPForum::Config->new(
            environment    => 'production-small',
            glifistore_url => $CUSTOM_GLIFISTORE_URL,
            metrics_token  => undef,
            session_secret => 'rotated-production-secret',
        )->validate;
    },
    qr/\A production [ ] requires [ ] GPFORUM_METRICS_TOKEN/msx,
    'production-small rejects an undefined metrics scrape token',
);

is(
    GPForum::Config->new(
        environment    => 'staging',
        glifistore_url => $CUSTOM_GLIFISTORE_URL,
        metrics_token  => $CUSTOM_METRICS_TOKEN,
        session_secret => 'rotated-staging-secret',
    )->validate->metrics_token,
    $CUSTOM_METRICS_TOKEN,
    'staging accepts a configured metrics scrape token'
);

is( GPForum::Config->new->validate->metrics_token,
    q{}, 'development keeps the metrics scrape token optional' );

my $rotated = GPForum::Config->from_environment(
    {
        GPFORUM_ENV             => 'test',
        GPFORUM_METRICS_TOKEN   => 'now-token',
        GPFORUM_METRICS_TOKENS  => ' old-token , now-token, older-token, ',
        GPFORUM_SESSION_SECRET  => 'current-secret',
        GPFORUM_SESSION_SECRETS =>
          ' previous-one , current-secret, previous-two, ',
    }
);
is_deeply(
    $rotated->signing_secrets,
    [ 'current-secret', 'previous-one', 'previous-two' ],
    'signing secrets keep the current secret first and drop duplicates'
);
is_deeply(
    $rotated->accepted_metrics_tokens,
    [ 'now-token', 'old-token', 'older-token' ],
    'accepted metrics tokens keep the current token first and drop duplicates'
);

throws_ok(
    sub {
        GPForum::Config->new(
            environment              => 'production',
            glifistore_url           => $CUSTOM_GLIFISTORE_URL,
            previous_session_secrets =>
              ['gpforum-development-secret-change-me'],
            session_secret => 'rotated-production-secret',
        )->validate;
    },
    qr/\A $session_secret_prefix [ ] $session_secret_suffix/msx,
    'production previous session secrets reject the development default',
);

1;
