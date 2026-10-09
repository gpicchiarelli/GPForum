# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Config;
use GPForum::Config::Report;
use GPForum::Runtime;

our $VERSION = '0.001';

# Each setting's variable, by its attribute: a refusal names the variable an
# operator sets, not the attribute.
my %VARIABLE = map { $_->{name} => $_->{env} } @{ GPForum::Config->settings };

# A production configuration with nothing wrong: an https address, a sender
# at the forum's domain, a long session secret and a metrics token.
const my $PRODUCTION_SECRET => 'p' x 40;
const my %PRODUCTION => (
    environment     => 'production',
    public_base_url => 'https://forum.example.test',
    mail_from       => 'forum@forum.example.test',
    metrics_token   => 'metrics-secret',
    session_secret  => $PRODUCTION_SECRET,
);
const my %PRODUCTION_ENV => (
    GPFORUM_ENV             => 'production',
    GPFORUM_PUBLIC_BASE_URL => 'https://forum.example.test',
    GPFORUM_MAIL_FROM       => 'forum@forum.example.test',
    GPFORUM_METRICS_TOKEN   => 'metrics-secret',
    GPFORUM_SESSION_SECRET  => $PRODUCTION_SECRET,
);

const my $EXPECTED_TESTS             => 323;
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
const my $DEFAULT_CACHE_MAX_ENTRIES  => 4_096;
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
const my $BELOW_ZERO                 => -1;
const my $DEFAULT_STATEMENT_TIMEOUT_MS => 15_000;
const my $DEFAULT_IDLE_IN_TXN_MS       => 10_000;
const my $DEFAULT_LOCK_TIMEOUT_MS      => 3_000;
const my $CUSTOM_STATEMENT_TIMEOUT_MS  => 7_000;
const my $DEFAULT_SEARCH_TIMEOUT_MS    => 2_000;
const my $DEFAULT_SEARCH_CANDIDATES    => 1_000;
const my $CUSTOM_SEARCH_TIMEOUT_MS     => 500;
const my $CUSTOM_SEARCH_CANDIDATES     => 250;
const my $LOWERED_STATEMENT_TIMEOUT_MS => 1_500;
const my $CLAMD_TIMEOUT_SECONDS        => 30;
const my $COMMAND_TIMEOUT_SECONDS      => 120;

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
is(
    _refusal(
        sub {
            GPForum::Config->new( runtime_trusted_proxies => q{ , } )->validate;
        }
    ),
    'GPFORUM_RUNTIME_TRUSTED_PROXIES must name at least one address'
      . ' while GPFORUM_RUNTIME_PROXY is on.',
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
is( $config->smtp_tls, 'starttls',
    'the old GPFORUM_SMTP_SSL=1 still reads, as STARTTLS' );
my $default_config = GPForum::Config->new;
is( $default_config->log_level,
    $DEFAULT_LOG_LEVEL, 'log level default is production-oriented' );
is( $default_config->metrics_token,
    q{}, 'metrics token is optional by default' );
is( $default_config->glifistore_url,
    q{}, 'GlifiStore URL defaults to none: each process caches on its own' );
is( $default_config->mail_transport,
    'test', 'mail transport defaults to the test adapter' );
is( $default_config->mail_from,
    'noreply@localhost', 'mail from defaults to a local sender' );
ok( $default_config->requires_glifistore == 0,
    'development does not require an explicit GlifiStore URL' );
ok(
    !GPForum::Config->new( environment => 'production-small' )
      ->requires_glifistore,
    'production-small does not require GlifiStore'
);
ok( !GPForum::Config->environment_requires_glifistore('staging'),
    'staging does not require GlifiStore' );
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
        # text when no SQLSTATE is visible, so the locale is pinned -- asked
        # for, not demanded: PostgreSQL lets only a superuser set it, and an
        # ordinary role must still connect (t/integration/postgres-plain-role.t).
        q{DO $$ BEGIN PERFORM set_config('lc_messages', 'C', false);}
          . q{ EXCEPTION WHEN insufficient_privilege THEN NULL; END $$},

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

is(
    _refusal(
        sub {
            GPForum::Config->new( database_statement_timeout_ms => -1 )
              ->validate;
        }
    ),
    'GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS must be at least 0, not -1.',
    'negative statement timeout fails validation'
);

# Search's own budget (8.10): a statement timeout well under the one every
# query gets, and how many of the newest matches it ranks.
is( $default_config->search_statement_timeout_ms,
    $DEFAULT_SEARCH_TIMEOUT_MS, 'search has its own statement timeout' );
is( $default_config->search_candidate_limit,
    $DEFAULT_SEARCH_CANDIDATES, 'search ranks the newest 1,000 matches' );

my $search_config = GPForum::Config->from_environment(
    {
        %environment,
        GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS => $CUSTOM_SEARCH_TIMEOUT_MS,
        GPFORUM_SEARCH_CANDIDATE_LIMIT      => $CUSTOM_SEARCH_CANDIDATES,
    }
);
is( $search_config->search_statement_timeout_ms,
    $CUSTOM_SEARCH_TIMEOUT_MS, 'search statement timeout loads from env' );
is( $search_config->search_candidate_limit,
    $CUSTOM_SEARCH_CANDIDATES, 'search candidate limit loads from env' );

is(
    _refusal(
        sub {
            GPForum::Config->new( search_statement_timeout_ms => -1 )->validate;
        }
    ),
    'GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS must be at least 0, not -1.',
    'negative search statement timeout fails validation'
);

# Search is cut off before every other query, never after. An operator who
# lowered the connection's statement timeout below search's default gave
# search more time than anything else; it is now held to the connection's.
is(
    GPForum::Config->from_environment(
        {
            %environment,
            GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS =>
              $LOWERED_STATEMENT_TIMEOUT_MS,
        }
    )->search_statement_timeout_ms,
    $LOWERED_STATEMENT_TIMEOUT_MS,
    q{search's timeout is lowered to a lower connection timeout}
);
is(
    GPForum::Config->from_environment(
        {
            %environment,
            GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS =>
              $LOWERED_STATEMENT_TIMEOUT_MS,
            GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS => $CUSTOM_SEARCH_TIMEOUT_MS,
        }
    )->search_statement_timeout_ms,
    $CUSTOM_SEARCH_TIMEOUT_MS,
    'and left alone when it is already below it'
);
is(
    GPForum::Config->from_environment(
        { %environment, GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS => 0 }
    )->search_statement_timeout_ms,
    $DEFAULT_SEARCH_TIMEOUT_MS,
    'a connection without a timeout leaves search its own'
);
is(
    GPForum::Config->from_environment(
        {
            %environment,
            GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS =>
              $LOWERED_STATEMENT_TIMEOUT_MS,
            GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS => 0,
        }
    )->search_statement_timeout_ms,
    0,
    q{and zero for search still means the connection's}
);
is(
    _refusal(
        sub {
            GPForum::Config->new(
                database_statement_timeout_ms => $LOWERED_STATEMENT_TIMEOUT_MS,
                search_statement_timeout_ms   => $DEFAULT_SEARCH_TIMEOUT_MS,
            )->validate;
        }
    ),
    'GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS must not exceed'
      . ' GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS (1500), not 2000.',
    'a built configuration whose search outlasts the connection is refused'
);

is(
    _refusal(
        sub {
            GPForum::Config->new( search_candidate_limit => 0 )->validate;
        }
    ),
    'GPFORUM_SEARCH_CANDIDATE_LIMIT must be at least 1, not 0.',
    'a search that ranks no candidate fails validation'
);

is(
    _refusal(
        sub {
            GPForum::Config->from_environment(
                { GPFORUM_SEARCH_CANDIDATE_LIMIT => 'all' } );
        }
    ),
    q{GPFORUM_SEARCH_CANDIDATE_LIMIT must be a whole number, not 'all'.},
    'a non-integer search candidate limit fails validation'
);

is(
    _refusal(
        sub {
            GPForum::Config->from_environment(
                { GPFORUM_WEB_PROCESSES => 'zero' } );
        }
    ),
    q{GPFORUM_WEB_PROCESSES must be a whole number or auto, not 'zero'.},
    'non-integer process count fails validation'
);

is(
    _refusal(
        sub {
            GPForum::Config->new( os_reuseport => 'maybe' )->validate;
        }
    ),
    q{GPFORUM_OS_REUSEPORT must be one of auto, on, off, not 'maybe'.},
    'invalid OS feature flag fails validation'
);

is(
    _refusal(
        sub {
            GPForum::Config->new( runtime_worker_policy => 'mystery' )
              ->validate;
        }
    ),
    q{GPFORUM_RUNTIME_WORKER_POLICY must be one of configured, cap-to-cpu,}
      . q{ not 'mystery'.},
    'invalid runtime worker policy fails validation'
);

is(
    _refusal(
        sub {
            GPForum::Config->new( default_theme => 'neon' )->validate;
        }
    ),
    q{GPFORUM_DEFAULT_THEME must be one of auto, default, dark,}
      . q{ high_contrast, not 'neon'.},
    'invalid default theme fails validation'
);

is(
    _refusal(
        sub {
            GPForum::Config->new( runtime_proxy => 2 )->validate;
        }
    ),
    q{GPFORUM_RUNTIME_PROXY must be on or off, not '2'.},
    'runtime proxy must be boolean integer'
);

is(
    _refusal(
        sub {
            GPForum::Config->new( realtime_listener_enabled => 2 )->validate;
        }
    ),
    q{GPFORUM_REALTIME_LISTENER_ENABLED must be on or off, not '2'.},
    'realtime listener enabled flag must be boolean integer'
);

is(
    _refusal(
        sub {
            GPForum::Config->new( minion_enabled => 2 )->validate;
        }
    ),
    q{GPFORUM_MINION_ENABLED must be on or off, not '2'.},
    'Minion enabled flag must be boolean integer'
);

is(
    _refusal(
        sub {
            GPForum::Config->new( minion_enabled => 1 )->validate;
        }
    ),
    'GPFORUM_MINION_PG_URL is required while GPFORUM_MINION_ENABLED is on.',
    'Minion enabled requires PostgreSQL URL'
);

is(
    _refusal(
        sub {
            GPForum::Config->new( glifistore_url => 'redis://localhost' )
              ->validate;
        }
    ),
    'GPFORUM_GLIFISTORE_URL must be tcp://host:port, unix://path or'
      . q{ host:port, not 'redis://localhost'.},
    'invalid GlifiStore URL fails validation'
);

# GlifiStore is optional everywhere (D2): a deployed configuration without
# one is complete.
lives_ok {
    GPForum::Config->new( %PRODUCTION, glifistore_url => q{} )->validate
}
'production validates without GlifiStore';
lives_ok {
    GPForum::Config->from_environment(
        {
            GPFORUM_ENV            => 'staging',
            GPFORUM_METRICS_TOKEN  => $CUSTOM_METRICS_TOKEN,
            GPFORUM_SESSION_SECRET => 'rotated-staging-secret',
        }
    );
}
'staging starts without GlifiStore';

for my $environment (qw(production staging production-medium)) {
    like(
        _refusal(
            sub {
                GPForum::Config->from_environment(
                    {
                        %PRODUCTION_ENV,
                        GPFORUM_ENV            => $environment,
                        GPFORUM_SESSION_SECRET =>
                          'gpforum-development-secret-change-me',
                    },
                );
            }
        ),
        qr{^GPFORUM_SESSION_SECRET [ ] is [ ] required [ ] in [ ]
          \Q$environment\E [.] $}msx,
        "$environment rejects the default session secret",
    );
}

is(
    _refusal(
        sub {
            GPForum::Config->new( session_secret => q{} )->validate;
        }
    ),
    'GPFORUM_SESSION_SECRET is required.',
    'empty session secret fails validation'
);

is(
    _refusal(
        sub {
            GPForum::Config->new( web_processes => 0 )->validate;
        }
    ),
    'GPFORUM_WEB_PROCESSES must be at least 1, not 0.',
    'minimum process bound is enforced'
);

is(
    _refusal(
        sub {
            GPForum::Config->new( web_processes => $TOO_MANY_PROCESSES )
              ->validate;
        }
    ),
    'GPFORUM_WEB_PROCESSES must be at most 512, not 513.',
    'maximum process bound is enforced'
);

is(
    _refusal(
        sub {
            GPForum::Config->new( os_max_open_file_descriptors => 0 )->validate;
        }
    ),
    'GPFORUM_OS_MAX_OPEN_FILE_DESCRIPTORS must be at least 1, not 0.',
    'OS preflight thresholds require positive values'
);

is(
    _refusal(
        sub {
            GPForum::Config->new( local_cache_max_entries => 0 )->validate;
        }
    ),
    'GPFORUM_LOCAL_CACHE_MAX_ENTRIES must be at least 1, not 0.',
    'local cache max entries require positive values'
);

is(
    _refusal(
        sub {
            GPForum::Config->new( category_cache_ttl_seconds => 0 )->validate;
        }
    ),
    'GPFORUM_CATEGORY_CACHE_TTL_SECONDS must be at least 1, not 0.',
    'category cache TTL requires positive values'
);

is(
    GPForum::Config->from_environment( \%PRODUCTION_ENV )->mail_transport,
    'sendmail',
    'production defaults to sendmail transport'
);

is(
    _refusal(
        sub {
            GPForum::Config->from_environment(
                { %PRODUCTION_ENV, GPFORUM_METRICS_TOKEN => q{} } );
        }
    ),
    'GPFORUM_METRICS_TOKEN is required in production.',
    'production fails closed without a metrics scrape token',
);

is(
    _refusal(
        sub {
            GPForum::Config->from_environment(
                {
                    GPFORUM_ENV            => 'staging',
                    GPFORUM_METRICS_TOKEN  => q{},
                    GPFORUM_SESSION_SECRET => 'rotated-staging-secret',
                },
            );
        }
    ),
    'GPFORUM_METRICS_TOKEN is required in staging.',
    'staging rejects an empty metrics scrape token',
);

is(
    _refusal(
        sub {
            GPForum::Config->new(
                %PRODUCTION,
                environment   => 'production-small',
                metrics_token => undef,
            )->validate;
        }
    ),
    'GPFORUM_METRICS_TOKEN is required in production-small.',
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

is(
    _refusal(
        sub {
            GPForum::Config->new( %PRODUCTION,
                previous_session_secrets =>
                  ['gpforum-development-secret-change-me'], )->validate;
        }
    ),
    'GPFORUM_SESSION_SECRETS must not include the development default.',
    'production previous session secrets reject the development default',
);

# Config builds the refusal of a value outside a setting's list from the list
# itself, so each such message is pinned here word for word.
for my $case (
    [
        default_theme => 'pinned',
        'GPFORUM_DEFAULT_THEME must be one of auto, default, dark,'
          . q{ high_contrast, not 'pinned'.}
    ],
    [
        mail_transport => 'pigeon',
        'GPFORUM_MAIL_TRANSPORT must be one of sendmail, smtp, log, test,'
          . q{ not 'pigeon'.}
    ],
    [
        antivirus => 'hope',
        q{GPFORUM_ANTIVIRUS must be one of clamd, command, none, not 'hope'.}
    ],
    [
        default_timezone => 'Mars/Olympus',
        'GPFORUM_DEFAULT_TIMEZONE must be an IANA time zone such as'
          . q{ Europe/Rome, not 'Mars/Olympus'.}
    ],
  )
{
    my ( $name, $value, $message ) = @{$case};
    is( _refusal( sub { GPForum::Config->new( $name => $value )->validate } ),
        $message, "$name refuses $value with the exact message" );
}

# A deployed profile read from the environment defaults to sendmail, clamd
# and no GlifiStore; the same profile built with new keeps the plain
# defaults. An antivirus command gets the longer scan timeout.
my $read_staging = GPForum::Config->from_environment(
    {
        GPFORUM_ENV            => 'staging',
        GPFORUM_GLIFISTORE_URL => $CUSTOM_GLIFISTORE_URL,
        GPFORUM_METRICS_TOKEN  => $CUSTOM_METRICS_TOKEN,
        GPFORUM_SESSION_SECRET => 'rotated-staging-secret',
    }
);
is_deeply(
    [
        map { $read_staging->$_ }
          qw(mail_transport antivirus antivirus_timeout_seconds)
    ],
    [ 'sendmail', 'clamd', $CLAMD_TIMEOUT_SECONDS ],
    'staging read from the environment defaults to sendmail and clamd'
);
my $built_staging = GPForum::Config->new( environment => 'staging' );
is_deeply(
    [ map { $built_staging->$_ } qw(mail_transport antivirus glifistore_url) ],
    [ 'test', 'none', q{} ],
    'staging built with new keeps the plain defaults'
);
my $scanning = GPForum::Config->from_environment(
    {
        GPFORUM_ANTIVIRUS         => 'command',
        GPFORUM_ANTIVIRUS_COMMAND => ' clamscan  --no-summary ',
    }
);
is_deeply(
    [ $scanning->antivirus_timeout_seconds, $scanning->antivirus_command ],
    [ $COMMAND_TIMEOUT_SECONDS,             [qw(clamscan --no-summary)] ],
    'an antivirus command is split into words and gets the longer timeout'
);

# Every setting by its variable, its value read from that variable and its
# default, written out here rather than taken from Config's table: a renamed
# variable or a changed default fails one of these. Each value differs from
# the default, and together they make one valid configuration. A fifth value
# is the default read from an empty environment -- development -- when it is
# not the one new gives.
my $automatic_web = GPForum::Config->new->automatic_web_processes;
my @every_setting = (
    [ environment => 'GPFORUM_ENV',       'development', 'test' ],
    [ log_level   => 'GPFORUM_LOG_LEVEL', 'info',        'debug' ],
    [ log_path    => 'GPFORUM_LOG_PATH',  q{}, '/var/log/gpforum.log' ],
    [
        attachment_root => 'GPFORUM_ATTACHMENT_ROOT',
        'var/attachments', '/srv/files'
    ],
    [
        attachment_accel_redirect => 'GPFORUM_ATTACHMENT_ACCEL_REDIRECT',
        q{}, '/protected'
    ],
    [ default_locale   => 'GPFORUM_DEFAULT_LOCALE',   'en',   'it' ],
    [ default_theme    => 'GPFORUM_DEFAULT_THEME',    'auto', 'dark' ],
    [ default_timezone => 'GPFORUM_DEFAULT_TIMEZONE', 'UTC',  'Europe/Rome' ],
    [
        public_base_url => 'GPFORUM_PUBLIC_BASE_URL',
        'http://127.0.0.1:3000', 'https://forum.example'
    ],
    [
        session_secret => 'GPFORUM_SESSION_SECRET',
        'gpforum-development-secret-change-me', 'read-secret'
    ],
    [
        database_dsn => 'GPFORUM_DATABASE_DSN',
        'dbi:Pg:dbname=gpforum;host=127.0.0.1;port=5432', 'dbi:Pg:dbname=other'
    ],
    [ database_user     => 'GPFORUM_DATABASE_USER',     'gpforum', 'reader' ],
    [ database_password => 'GPFORUM_DATABASE_PASSWORD', q{},       'hunter' ],
    [
        database_statement_timeout_ms =>
          'GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS',
        '15000', '20000'
    ],
    [
        database_idle_in_transaction_timeout_ms =>
          'GPFORUM_DATABASE_IDLE_IN_TRANSACTION_TIMEOUT_MS',
        '10000', '11000'
    ],
    [
        database_lock_timeout_ms => 'GPFORUM_DATABASE_LOCK_TIMEOUT_MS',
        '3000', '4000'
    ],
    [
        search_statement_timeout_ms => 'GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS',
        '2000', '2500'
    ],
    [
        search_candidate_limit => 'GPFORUM_SEARCH_CANDIDATE_LIMIT',
        '1000', '900'
    ],
    [ web_processes      => 'GPFORUM_WEB_PROCESSES',      $automatic_web, '3' ],
    [ worker_processes   => 'GPFORUM_WORKER_PROCESSES',   '2',            '5' ],
    [ realtime_processes => 'GPFORUM_REALTIME_PROCESSES', '1',            '2' ],
    [
        runtime_listen => 'GPFORUM_RUNTIME_LISTEN',
        'http://127.0.0.1:8080', 'http://0.0.0.0:9000'
    ],
    [
        runtime_pid_file => 'GPFORUM_RUNTIME_PID_FILE',
        'hypnotoad.pid', 'gpforum.pid'
    ],
    [
        runtime_worker_policy => 'GPFORUM_RUNTIME_WORKER_POLICY',
        'cap-to-cpu', 'configured'
    ],
    [
        runtime_max_web_per_cpu => 'GPFORUM_RUNTIME_MAX_WEB_PER_CPU',
        '2', '3'
    ],
    [ runtime_backlog  => 'GPFORUM_RUNTIME_BACKLOG',  '256',  '128' ],
    [ runtime_clients  => 'GPFORUM_RUNTIME_CLIENTS',  '250',  '100' ],
    [ runtime_requests => 'GPFORUM_RUNTIME_REQUESTS', '1000', '500' ],
    [
        runtime_keep_alive => 'GPFORUM_RUNTIME_KEEP_ALIVE_TIMEOUT',
        '5', '6'
    ],
    [
        runtime_inactivity => 'GPFORUM_RUNTIME_INACTIVITY_TIMEOUT',
        '30', '31'
    ],
    [
        runtime_graceful_timeout => 'GPFORUM_RUNTIME_GRACEFUL_TIMEOUT',
        '20', '21'
    ],
    [
        runtime_heartbeat_interval => 'GPFORUM_RUNTIME_HEARTBEAT_INTERVAL',
        '5', '7'
    ],
    [
        runtime_heartbeat_timeout => 'GPFORUM_RUNTIME_HEARTBEAT_TIMEOUT',
        '5', '8'
    ],
    [
        runtime_upgrade_timeout => 'GPFORUM_RUNTIME_UPGRADE_TIMEOUT',
        '60', '61'
    ],
    [
        runtime_spare_processes => 'GPFORUM_RUNTIME_SPARE_PROCESSES',
        '1', '2'
    ],
    [ runtime_proxy => 'GPFORUM_RUNTIME_PROXY', '1', '0' ],
    [
        runtime_trusted_proxies => 'GPFORUM_RUNTIME_TRUSTED_PROXIES',
        '127.0.0.1,::1', '10.0.0.1'
    ],
    [ os_reuseport        => 'GPFORUM_OS_REUSEPORT',        'auto', 'on' ],
    [ os_sendfile         => 'GPFORUM_OS_SENDFILE',         'auto', 'off' ],
    [ os_worker_priority  => 'GPFORUM_OS_WORKER_PRIORITY',  'auto', 'on' ],
    [ os_static_xsendfile => 'GPFORUM_OS_STATIC_XSENDFILE', 'auto', 'off' ],
    [ os_affinity         => 'GPFORUM_OS_AFFINITY',         'off',  'manual' ],
    [
        os_min_recommended_workers => 'GPFORUM_OS_MIN_RECOMMENDED_WORKERS',
        '2', '3'
    ],
    [
        os_max_open_file_descriptors => 'GPFORUM_OS_MAX_OPEN_FILE_DESCRIPTORS',
        '65536', '1024'
    ],
    [
        local_cache_max_entries => 'GPFORUM_LOCAL_CACHE_MAX_ENTRIES',
        '4096', '100'
    ],
    [
        category_cache_ttl_seconds => 'GPFORUM_CATEGORY_CACHE_TTL_SECONDS',
        '60', '61'
    ],
    [
        realtime_listener_enabled => 'GPFORUM_REALTIME_LISTENER_ENABLED',
        '1', '0'
    ],
    [
        realtime_listener_poll_interval_seconds =>
          'GPFORUM_REALTIME_LISTENER_POLL_INTERVAL_SECONDS',
        '1', '2'
    ],
    [
        realtime_listener_reconnect_backoff_seconds =>
          'GPFORUM_REALTIME_LISTENER_RECONNECT_BACKOFF_SECONDS',
        '5', '6'
    ],
    [
        realtime_listener_heartbeat_interval_seconds =>
          'GPFORUM_REALTIME_LISTENER_HEARTBEAT_INTERVAL_SECONDS',
        '30', '31'
    ],
    [ minion_enabled => 'GPFORUM_MINION_ENABLED', '0', '1' ],
    [ minion_pg_url  => 'GPFORUM_MINION_PG_URL',  q{}, 'postgresql://minion' ],
    [ metrics_token  => 'GPFORUM_METRICS_TOKEN',  q{}, 'read-token' ],
    [
        glifistore_url => 'GPFORUM_GLIFISTORE_URL',
        q{}, 'unix:///run/glifistore.sock'
    ],
    [
        session_touch_interval_seconds =>
          'GPFORUM_SESSION_TOUCH_INTERVAL_SECONDS',
        '300', '301'
    ],
    [
        forum_read_rate_limit => 'GPFORUM_FORUM_READ_RATE_LIMIT',
        '60', '600'
    ],
    [ mail_transport => 'GPFORUM_MAIL_TRANSPORT', 'test', 'smtp', 'log' ],
    [
        mail_from => 'GPFORUM_MAIL_FROM',
        'noreply@localhost', 'forum@example.org'
    ],
    [ smtp_host     => 'GPFORUM_SMTP_HOST',     q{},   'smtp.example.org' ],
    [ smtp_port     => 'GPFORUM_SMTP_PORT',     '587', '25' ],
    [ smtp_username => 'GPFORUM_SMTP_USERNAME', q{},   'mailer' ],
    [ smtp_password => 'GPFORUM_SMTP_PASSWORD', q{},   'mailpass' ],
    [ smtp_tls      => 'GPFORUM_SMTP_TLS',      'starttls', 'implicit' ],
    [ antivirus     => 'GPFORUM_ANTIVIRUS',     'none',     'clamd' ],
    [
        antivirus_socket => 'GPFORUM_ANTIVIRUS_SOCKET',
        q{}, '/run/clamd.ctl'
    ],
    [
        antivirus_timeout_seconds => 'GPFORUM_ANTIVIRUS_TIMEOUT_SECONDS',
        '30', '45'
    ],
);
my %every_variable = (
    GPFORUM_SESSION_SECRETS   => 'older, oldest',
    GPFORUM_METRICS_TOKENS    => 'older-token',
    GPFORUM_ANTIVIRUS_COMMAND => 'scan --quiet',
);
for my $setting (@every_setting) {
    my ( undef, $variable, undef, $value ) = @{$setting};
    $every_variable{$variable} = $value;
}
my $read_every    = GPForum::Config->from_environment( \%every_variable );
my $built_default = GPForum::Config->new;
my $read_default  = GPForum::Config->from_environment( {} );
for my $setting (@every_setting) {
    my ( $name, $variable, $default, $value, $read ) = @{$setting};
    $read //= $default;
    is( $read_every->$name, $value, "$variable sets $name" );
    is_deeply(
        [ $built_default->$name, $read_default->$name ],
        [ $default,              $read ],
        "$name defaults to '$default' built, '$read' read"
    );
}
is_deeply(
    [
        map { $read_every->$_ }
          qw(previous_session_secrets previous_metrics_tokens antivirus_command)
    ],
    [ [qw(older oldest)], ['older-token'], [qw(scan --quiet)] ],
    'the list settings are read from their variables'
);
is_deeply(
    [
        map { $built_default->$_ }
          qw(previous_session_secrets previous_metrics_tokens antivirus_command)
    ],
    [ [], [], [] ],
    'the list settings default to empty'
);
isnt(
    $built_default->previous_session_secrets,
    GPForum::Config->new->previous_session_secrets,
    'each configuration built with new gets its own empty list'
);

for my $name (
    qw(environment log_level default_locale public_base_url session_secret
    database_dsn database_user runtime_listen runtime_pid_file mail_transport
    mail_from)
  )
{
    is(
        _refusal( sub { GPForum::Config->new( $name => q{} )->validate } ),
        "$VARIABLE{$name} is required.",
        "an empty $name is refused"
    );
}
is(
    _refusal( sub { GPForum::Config->new( smtp_port => 0 )->validate } ),
    'GPFORUM_SMTP_PORT must be at least 1, not 0.',
    'smtp_port 0 is refused'
);
is(
    GPForum::Config->from_environment( { GPFORUM_RUNTIME_BACKLOG => '0064' } )
      ->runtime_backlog,
    '64',
    'an integer read with leading zeros is the number'
);
lives_ok {
    GPForum::Config->new( runtime_proxy => 0, runtime_trusted_proxies => q{} )
      ->validate
}
'no trusted proxy is needed when the proxy is off';
is_deeply(
    GPForum::Config->new(
        session_secret           => 'current',
        previous_session_secrets => [ q{}, 'current', 'older' ],
    )->signing_secrets,
    [qw(current older)],
    'signing secrets drop empty and repeated previous secrets'
);
is_deeply(
    GPForum::Config->from_environment(
        { GPFORUM_RUNTIME_LISTEN => ' http://a:1 ,http://b:2,, ' }
    )->runtime_listen_locations,
    [qw(http://a:1 http://b:2)],
    'listen locations are trimmed and empty ones dropped'
);
is_deeply(
    [
        map { $built_default->$_ }
          qw(requires_secure_transport requires_glifistore)
    ],
    [ 0, 0 ],
    'development requires neither secure transport nor GlifiStore, as 0'
);
my %connect_attributes =
  %{ ( $built_default->database_connect_info )[$CONNECT_ATTR_INDEX] };
delete $connect_attributes{on_connect_do};
is_deeply(
    \%connect_attributes,
    { AutoCommit => 1, RaiseError => 1, PrintError => 0, pg_enable_utf8 => 1 },
    'connect info asks DBI for autocommit, raised errors and UTF-8'
);

# A read-only environment hash, such as a Const::Fast one, refuses a read of
# a key it does not hold; from_environment only asks whether it is there.
const my %READ_ONLY_ENVIRONMENT => ( GPFORUM_ENV => 'test' );
is( GPForum::Config->from_environment( \%READ_ONLY_ENVIRONMENT )->environment,
    'test', 'a read-only environment hash is read' );
lives_ok {
    GPForum::Config->new( %PRODUCTION, previous_session_secrets => undef )
      ->validate
}
'a production configuration built without previous secrets validates';

# Each integer setting's own check, one value past its bound: a row that lost
# its check in the settings table would accept it.
for my $name (
    qw(search_candidate_limit runtime_max_web_per_cpu runtime_backlog
    runtime_clients runtime_requests runtime_keep_alive runtime_inactivity
    runtime_graceful_timeout runtime_heartbeat_interval
    runtime_heartbeat_timeout runtime_upgrade_timeout runtime_spare_processes
    os_min_recommended_workers os_max_open_file_descriptors
    local_cache_max_entries category_cache_ttl_seconds
    realtime_listener_poll_interval_seconds
    realtime_listener_reconnect_backoff_seconds
    realtime_listener_heartbeat_interval_seconds
    session_touch_interval_seconds smtp_port antivirus_timeout_seconds)
  )
{
    is(
        _refusal( sub { GPForum::Config->new( $name => 0 )->validate } ),
        "$VARIABLE{$name} must be at least 1, not 0.",
        "$name 0 is refused"
    );
}
for my $name (
    qw(database_statement_timeout_ms database_idle_in_transaction_timeout_ms
    database_lock_timeout_ms search_statement_timeout_ms)
  )
{
    is(
        _refusal(
            sub { GPForum::Config->new( $name => $BELOW_ZERO )->validate }
        ),
        "$VARIABLE{$name} must be at least 0, not -1.",
        "a negative $name is refused"
    );
}
for my $name (qw(runtime_proxy realtime_listener_enabled minion_enabled)) {
    for my $value ( $BELOW_ZERO, 2 ) {
        is(
            _refusal(
                sub { GPForum::Config->new( $name => $value )->validate }
            ),
            "$VARIABLE{$name} must be on or off, not '$value'.",
            "$name $value is refused"
        );
    }
}
for my $name (qw(web_processes)) {
    is(
        _refusal( sub { GPForum::Config->new( $name => 0 )->validate } ),
        "$VARIABLE{$name} must be at least 1, not 0.",
        "$name 0 is refused"
    );
    is(
        _refusal(
            sub {
                GPForum::Config->new( $name => $TOO_MANY_PROCESSES )->validate;
            }
        ),
        "$VARIABLE{$name} must be at most 512, not 513.",
        "$name above 512 is refused"
    );
}
is(
    _refusal(
        sub { GPForum::Config->new( antivirus => 'command' )->validate }
    ),
    'GPFORUM_ANTIVIRUS_COMMAND is required when GPFORUM_ANTIVIRUS is command.',
    'the command antivirus without a command is refused'
);

my @read_warnings;
{
    local $SIG{__WARN__} = sub ($warning) { push @read_warnings, $warning };
    GPForum::Config->from_environment( {} );
}
is_deeply( \@read_warnings, [],
    'reading an empty environment warns of nothing' );

my $refusal;
try {
    GPForum::Config->new( runtime_proxy => 2 )->validate;
}
catch ($error) {
    $refusal = $error;
};
isa_ok( $refusal, q{GPForum::X::Config}, q{an invalid setting} );
is( $refusal->failure_type, q{permanent},
    q{an invalid setting is a permanent failure, not one to retry} );

# The sentences of the problems a refused configuration reports, one a line;
# empty when it is not refused.
sub _refusal ($code) {
    try {
        $code->();
    }
    catch ($error) {
        return join "\n",
          map { GPForum::Config::Report->sentence($_) } @{ $error->problems };
    };

    return q{};
}

1;
