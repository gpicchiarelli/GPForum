# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Config;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;
use DateTime::TimeZone;

our $VERSION = '0.001';

const my $DEFAULT_ENVIRONMENT               => 'development';
const my $DEFAULT_LOG_LEVEL                 => 'info';
const my $DEFAULT_LOG_PATH                  => q{};
const my $DEFAULT_ATTACHMENT_ROOT           => 'var/attachments';
const my $DEFAULT_ATTACHMENT_ACCEL_REDIRECT => q{};
const my $DEFAULT_LOCALE                    => 'en';
const my $DEFAULT_THEME                     => 'default';
const my $DEFAULT_TIMEZONE                  => 'UTC';
const my $DEFAULT_PUBLIC_BASE_URL           => 'http://127.0.0.1:3000';
const my $DEFAULT_SESSION_SECRET => 'gpforum-development-secret-change-me';
const my $DEFAULT_DATABASE_DSN =>
  'dbi:Pg:dbname=gpforum;host=127.0.0.1;port=5432';
const my $DEFAULT_DATABASE_USER          => 'gpforum';
const my $DEFAULT_DATABASE_PASSWORD      => q{};
const my $DEFAULT_STATEMENT_TIMEOUT_MS   => 15_000;
const my $DEFAULT_IDLE_IN_TXN_TIMEOUT_MS => 10_000;
const my $DEFAULT_LOCK_TIMEOUT_MS        => 3_000;
const my $DEFAULT_SEARCH_TIMEOUT_MS      => 2_000;
const my $DEFAULT_SEARCH_CANDIDATES      => 1_000;
const my $SET_APPLICATION_NAME           => q{SET application_name = 'gpforum'};

# UniqueConflict falls back to matching "duplicate key" and "unique
# constraint" in the server's error text when it cannot see a SQLSTATE. Those
# are English strings: under any other lc_messages a real unique violation
# would read as an unknown error and the savepoint recovery would rethrow it.
const my $SET_MESSAGE_LOCALE => q{SET lc_messages = 'C'};

# The fuzzy-title threshold for search. Searcher matches titles with the pg_trgm
# % operator, which reads this setting, because % can use the trigram index and
# the similarity(...) >= ? it replaced could not. The value is the one Searcher
# used to bind; pg_trgm's own default of 0.3 would have quietly dropped every
# match between 0.18 and 0.3. Setting a pg_trgm parameter before the extension
# is loaded is allowed: PostgreSQL keeps it as a placeholder until then.
const my $SET_SEARCH_SIMILARITY => q{SET pg_trgm.similarity_threshold = 0.18};
const my $DEFAULT_WEB_PROCESSES => 4;
const my $DEFAULT_WORKER_PROCESSES        => 2;
const my $DEFAULT_REALTIME_PROCESSES      => 1;
const my $DEFAULT_RUNTIME_LISTEN          => 'http://127.0.0.1:8080';
const my $DEFAULT_RUNTIME_WORKER_POLICY   => 'cap-to-cpu';
const my $DEFAULT_RUNTIME_MAX_WEB_PER_CPU => 2;
const my $DEFAULT_RUNTIME_BACKLOG         => 256;
const my $DEFAULT_RUNTIME_CLIENTS         => 250;
const my $DEFAULT_RUNTIME_REQUESTS        => 1_000;
const my $DEFAULT_RUNTIME_KEEP_ALIVE      => 5;
const my $DEFAULT_RUNTIME_INACTIVITY      => 30;
const my $DEFAULT_RUNTIME_GRACEFUL        => 20;
const my $DEFAULT_RUNTIME_HEARTBEAT_INT   => 5;
const my $DEFAULT_RUNTIME_HEARTBEAT_TO    => 5;
const my $DEFAULT_RUNTIME_UPGRADE         => 60;
const my $DEFAULT_RUNTIME_SPARE           => 1;
const my $DEFAULT_RUNTIME_PROXY           => 1;
const my $DEFAULT_RUNTIME_TRUSTED_PROXIES => '127.0.0.1,::1';
const my $DEFAULT_RUNTIME_PID_FILE        => 'hypnotoad.pid';
const my $DEFAULT_OS_FEATURE_SETTING      => 'auto';
const my $DEFAULT_OS_AFFINITY             => 'off';
const my $DEFAULT_OS_MIN_WORKERS          => 2;
const my $DEFAULT_OS_MAX_OPEN_FDS         => 65_536;
const my $DEFAULT_LOCAL_CACHE_MAX_ENTRIES => 2_048;
const my $DEFAULT_CATEGORY_CACHE_TTL      => 60;
const my $DEFAULT_REALTIME_LISTENER       => 1;
const my $DEFAULT_REALTIME_POLL_SECONDS   => 1;
const my $DEFAULT_REALTIME_BACKOFF        => 5;
const my $DEFAULT_REALTIME_HEARTBEAT      => 30;
const my $DEFAULT_MINION_ENABLED          => 0;
const my $DEFAULT_MINION_PG_URL           => q{};
const my $DEFAULT_METRICS_TOKEN           => q{};
const my $DEFAULT_GLIFISTORE_URL          => 'tcp://127.0.0.1:7379';
const my $DEFAULT_SESSION_TOUCH_INTERVAL  => 300;
const my $DEFAULT_MAIL_TRANSPORT          => 'test';
const my $DEFAULT_MAIL_FROM               => 'noreply@localhost';
const my $DEFAULT_SMTP_HOST               => q{};
const my $DEFAULT_SMTP_PORT               => 587;
const my $DEFAULT_SMTP_USERNAME           => q{};
const my $DEFAULT_SMTP_PASSWORD           => q{};
const my $DEFAULT_SMTP_SSL                => 0;
const my $DEFAULT_ANTIVIRUS               => 'none';
const my $DEFAULT_ANTIVIRUS_TIMEOUT       => 30;
const my $DEFAULT_COMMAND_TIMEOUT         => 120;
const my $GLIFISTORE_TCP_URL =>
  qr{\A (?:tcp://)? [[:alnum:]._-]+ : [[:digit:]]+ \z}msx;
const my $GLIFISTORE_UNIX_URL => qr{\A unix:// \S+ \z}msx;
const my %REQUIRES_GLIFISTORE => map { $_ => 1 } qw(
  production
  production-medium
  production-small
  staging
);
const my $MINIMUM_PROCESS_COUNT    => 1;
const my $MAXIMUM_PROCESS_COUNT    => 512;
const my $MINIMUM_OS_THRESHOLD     => 1;
const my %VALID_OS_FEATURE_SETTING => map { $_ => 1 } qw(auto on off);
const my %VALID_OS_AFFINITY        => map { $_ => 1 } qw(off manual);
const my %VALID_RUNTIME_WORKER_POLICY => map { $_ => 1 }
  qw(configured cap-to-cpu);
const my %VALID_THEME => map { $_ => 1 } qw(default dark high_contrast);
const my %VALID_MAIL_TRANSPORT => map { $_ => 1 } qw(test smtp sendmail);
const my %VALID_ANTIVIRUS      => map { $_ => 1 } qw(clamd command none);
const my %ROTATED_SECRET_ENV => map { $_ => 1 } qw(
  production
  production-medium
  production-small
  staging
);

has environment     => sub { return $DEFAULT_ENVIRONMENT; };
has log_level       => sub { return $DEFAULT_LOG_LEVEL; };
has log_path        => sub { return $DEFAULT_LOG_PATH; };
has attachment_root => sub { return $DEFAULT_ATTACHMENT_ROOT; };
has attachment_accel_redirect =>
  sub { return $DEFAULT_ATTACHMENT_ACCEL_REDIRECT; };
has default_locale => sub { return $DEFAULT_LOCALE; };
has default_theme  => sub { return $DEFAULT_THEME; };

# The IANA zone dates are shown in for visitors and for members who have not
# chosen their own (9.3).
has default_timezone         => sub { return $DEFAULT_TIMEZONE; };
has public_base_url          => sub { return $DEFAULT_PUBLIC_BASE_URL; };
has session_secret           => sub { return $DEFAULT_SESSION_SECRET; };
has previous_session_secrets => sub { return []; };
has database_dsn             => sub { return $DEFAULT_DATABASE_DSN; };
has database_user            => sub { return $DEFAULT_DATABASE_USER; };
has database_password        => sub { return $DEFAULT_DATABASE_PASSWORD; };
has database_statement_timeout_ms =>
  sub { return $DEFAULT_STATEMENT_TIMEOUT_MS; };
has database_idle_in_transaction_timeout_ms =>
  sub { return $DEFAULT_IDLE_IN_TXN_TIMEOUT_MS; };
has database_lock_timeout_ms => sub { return $DEFAULT_LOCK_TIMEOUT_MS; };

# Search's own budget (8.10). A search holds a web worker for as long as the
# database takes, and there are few workers, so it is cut off well before the
# statement_timeout every other query gets; the page then says search is
# degraded. Search ranks only the newest search_candidate_limit matches, so a
# word most documents hold costs the same on any forum size.
has search_statement_timeout_ms => sub { return $DEFAULT_SEARCH_TIMEOUT_MS; };
has search_candidate_limit      => sub { return $DEFAULT_SEARCH_CANDIDATES; };
has web_processes               => sub { return $DEFAULT_WEB_PROCESSES; };
has worker_processes            => sub { return $DEFAULT_WORKER_PROCESSES; };
has realtime_processes          => sub { return $DEFAULT_REALTIME_PROCESSES; };
has runtime_listen              => sub { return $DEFAULT_RUNTIME_LISTEN; };
has runtime_worker_policy   => sub { return $DEFAULT_RUNTIME_WORKER_POLICY; };
has runtime_max_web_per_cpu => sub { return $DEFAULT_RUNTIME_MAX_WEB_PER_CPU; };
has runtime_backlog         => sub { return $DEFAULT_RUNTIME_BACKLOG; };
has runtime_clients         => sub { return $DEFAULT_RUNTIME_CLIENTS; };
has runtime_requests        => sub { return $DEFAULT_RUNTIME_REQUESTS; };
has runtime_keep_alive      => sub { return $DEFAULT_RUNTIME_KEEP_ALIVE; };
has runtime_inactivity      => sub { return $DEFAULT_RUNTIME_INACTIVITY; };
has runtime_graceful_timeout => sub { return $DEFAULT_RUNTIME_GRACEFUL; };
has runtime_heartbeat_interval =>
  sub { return $DEFAULT_RUNTIME_HEARTBEAT_INT; };
has runtime_heartbeat_timeout => sub { return $DEFAULT_RUNTIME_HEARTBEAT_TO; };
has runtime_upgrade_timeout   => sub { return $DEFAULT_RUNTIME_UPGRADE; };
has runtime_spare_processes   => sub { return $DEFAULT_RUNTIME_SPARE; };
has runtime_proxy             => sub { return $DEFAULT_RUNTIME_PROXY; };
has runtime_trusted_proxies => sub { return $DEFAULT_RUNTIME_TRUSTED_PROXIES; };
has runtime_pid_file        => sub { return $DEFAULT_RUNTIME_PID_FILE; };
has os_reuseport            => sub { return $DEFAULT_OS_FEATURE_SETTING; };
has os_sendfile             => sub { return $DEFAULT_OS_FEATURE_SETTING; };
has os_worker_priority      => sub { return $DEFAULT_OS_FEATURE_SETTING; };
has os_static_xsendfile     => sub { return $DEFAULT_OS_FEATURE_SETTING; };
has os_affinity             => sub { return $DEFAULT_OS_AFFINITY; };
has os_min_recommended_workers   => sub { return $DEFAULT_OS_MIN_WORKERS; };
has os_max_open_file_descriptors => sub { return $DEFAULT_OS_MAX_OPEN_FDS; };
has local_cache_max_entries => sub { return $DEFAULT_LOCAL_CACHE_MAX_ENTRIES; };
has category_cache_ttl_seconds => sub { return $DEFAULT_CATEGORY_CACHE_TTL; };
has realtime_listener_enabled  => sub { return $DEFAULT_REALTIME_LISTENER; };
has realtime_listener_poll_interval_seconds =>
  sub { return $DEFAULT_REALTIME_POLL_SECONDS; };
has realtime_listener_reconnect_backoff_seconds =>
  sub { return $DEFAULT_REALTIME_BACKOFF; };
has realtime_listener_heartbeat_interval_seconds =>
  sub { return $DEFAULT_REALTIME_HEARTBEAT; };
has minion_enabled          => sub { return $DEFAULT_MINION_ENABLED; };
has minion_pg_url           => sub { return $DEFAULT_MINION_PG_URL; };
has metrics_token           => sub { return $DEFAULT_METRICS_TOKEN; };
has previous_metrics_tokens => sub { return []; };
has glifistore_url          => sub { return $DEFAULT_GLIFISTORE_URL; };
has session_touch_interval_seconds =>
  sub { return $DEFAULT_SESSION_TOUCH_INTERVAL; };
has mail_transport => sub { return $DEFAULT_MAIL_TRANSPORT; };

# The free antivirus the operating system installed (ADR 0108): clamd, a
# command, or none. The socket defaults to the one the OS package declares.
has antivirus                 => sub { return $DEFAULT_ANTIVIRUS; };
has antivirus_socket          => sub { return q{}; };
has antivirus_command         => sub { return []; };
has antivirus_timeout_seconds => sub { return $DEFAULT_ANTIVIRUS_TIMEOUT; };
has mail_from                 => sub { return $DEFAULT_MAIL_FROM; };
has smtp_host                 => sub { return $DEFAULT_SMTP_HOST; };
has smtp_port                 => sub { return $DEFAULT_SMTP_PORT; };
has smtp_username             => sub { return $DEFAULT_SMTP_USERNAME; };
has smtp_password             => sub { return $DEFAULT_SMTP_PASSWORD; };
has smtp_ssl                  => sub { return $DEFAULT_SMTP_SSL; };

sub from_environment ( $class, $environment = undef ) {
    if ( !defined $environment ) {
        $environment = \%ENV;
    }

    my $self = $class->new(
        environment =>
          _env_value( $environment, 'GPFORUM_ENV', $DEFAULT_ENVIRONMENT ),
        log_level =>
          _env_value( $environment, 'GPFORUM_LOG_LEVEL', $DEFAULT_LOG_LEVEL ),
        log_path =>
          _env_value( $environment, 'GPFORUM_LOG_PATH', $DEFAULT_LOG_PATH ),
        attachment_root => _env_value(
            $environment, 'GPFORUM_ATTACHMENT_ROOT',
            $DEFAULT_ATTACHMENT_ROOT
        ),
        attachment_accel_redirect => _env_value(
            $environment,
            'GPFORUM_ATTACHMENT_ACCEL_REDIRECT',
            $DEFAULT_ATTACHMENT_ACCEL_REDIRECT
        ),
        default_locale =>
          _env_value( $environment, 'GPFORUM_DEFAULT_LOCALE', $DEFAULT_LOCALE ),
        default_theme =>
          _env_value( $environment, 'GPFORUM_DEFAULT_THEME', $DEFAULT_THEME ),
        default_timezone => _env_value(
            $environment, 'GPFORUM_DEFAULT_TIMEZONE', $DEFAULT_TIMEZONE
        ),
        public_base_url => _env_value(
            $environment, 'GPFORUM_PUBLIC_BASE_URL',
            $DEFAULT_PUBLIC_BASE_URL
        ),
        session_secret => _env_value(
            $environment, 'GPFORUM_SESSION_SECRET', $DEFAULT_SESSION_SECRET
        ),
        previous_session_secrets =>
          _env_csv( $environment, 'GPFORUM_SESSION_SECRETS' ),
        database_dsn => _env_value(
            $environment, 'GPFORUM_DATABASE_DSN', $DEFAULT_DATABASE_DSN
        ),
        database_user => _env_value(
            $environment, 'GPFORUM_DATABASE_USER', $DEFAULT_DATABASE_USER
        ),
        database_password => _env_value(
            $environment, 'GPFORUM_DATABASE_PASSWORD',
            $DEFAULT_DATABASE_PASSWORD
        ),
        database_statement_timeout_ms => _env_integer(
            $environment,
            'GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS',
            $DEFAULT_STATEMENT_TIMEOUT_MS
        ),
        database_idle_in_transaction_timeout_ms => _env_integer(
            $environment,
            'GPFORUM_DATABASE_IDLE_IN_TRANSACTION_TIMEOUT_MS',
            $DEFAULT_IDLE_IN_TXN_TIMEOUT_MS
        ),
        database_lock_timeout_ms => _env_integer(
            $environment, 'GPFORUM_DATABASE_LOCK_TIMEOUT_MS',
            $DEFAULT_LOCK_TIMEOUT_MS
        ),
        search_statement_timeout_ms => _env_integer(
            $environment, 'GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS',
            $DEFAULT_SEARCH_TIMEOUT_MS
        ),
        search_candidate_limit => _env_integer(
            $environment, 'GPFORUM_SEARCH_CANDIDATE_LIMIT',
            $DEFAULT_SEARCH_CANDIDATES
        ),
        web_processes => _env_integer(
            $environment, 'GPFORUM_WEB_PROCESSES', $DEFAULT_WEB_PROCESSES
        ),
        worker_processes => _env_integer(
            $environment, 'GPFORUM_WORKER_PROCESSES',
            $DEFAULT_WORKER_PROCESSES
        ),
        realtime_processes => _env_integer(
            $environment, 'GPFORUM_REALTIME_PROCESSES',
            $DEFAULT_REALTIME_PROCESSES
        ),
        runtime_listen => _env_value(
            $environment, 'GPFORUM_RUNTIME_LISTEN', $DEFAULT_RUNTIME_LISTEN
        ),
        runtime_worker_policy => _env_value(
            $environment, 'GPFORUM_RUNTIME_WORKER_POLICY',
            $DEFAULT_RUNTIME_WORKER_POLICY
        ),
        runtime_max_web_per_cpu => _env_integer(
            $environment,
            'GPFORUM_RUNTIME_MAX_WEB_PER_CPU',
            $DEFAULT_RUNTIME_MAX_WEB_PER_CPU
        ),
        runtime_backlog => _env_integer(
            $environment, 'GPFORUM_RUNTIME_BACKLOG',
            $DEFAULT_RUNTIME_BACKLOG
        ),
        runtime_clients => _env_integer(
            $environment, 'GPFORUM_RUNTIME_CLIENTS',
            $DEFAULT_RUNTIME_CLIENTS
        ),
        runtime_requests => _env_integer(
            $environment, 'GPFORUM_RUNTIME_REQUESTS',
            $DEFAULT_RUNTIME_REQUESTS
        ),
        runtime_keep_alive => _env_integer(
            $environment, 'GPFORUM_RUNTIME_KEEP_ALIVE_TIMEOUT',
            $DEFAULT_RUNTIME_KEEP_ALIVE
        ),
        runtime_inactivity => _env_integer(
            $environment, 'GPFORUM_RUNTIME_INACTIVITY_TIMEOUT',
            $DEFAULT_RUNTIME_INACTIVITY
        ),
        runtime_graceful_timeout => _env_integer(
            $environment, 'GPFORUM_RUNTIME_GRACEFUL_TIMEOUT',
            $DEFAULT_RUNTIME_GRACEFUL
        ),
        runtime_heartbeat_interval => _env_integer(
            $environment,
            'GPFORUM_RUNTIME_HEARTBEAT_INTERVAL',
            $DEFAULT_RUNTIME_HEARTBEAT_INT
        ),
        runtime_heartbeat_timeout => _env_integer(
            $environment,
            'GPFORUM_RUNTIME_HEARTBEAT_TIMEOUT',
            $DEFAULT_RUNTIME_HEARTBEAT_TO
        ),
        runtime_upgrade_timeout => _env_integer(
            $environment, 'GPFORUM_RUNTIME_UPGRADE_TIMEOUT',
            $DEFAULT_RUNTIME_UPGRADE
        ),
        runtime_spare_processes => _env_integer(
            $environment, 'GPFORUM_RUNTIME_SPARE_PROCESSES',
            $DEFAULT_RUNTIME_SPARE
        ),
        runtime_proxy => _env_integer(
            $environment, 'GPFORUM_RUNTIME_PROXY', $DEFAULT_RUNTIME_PROXY
        ),
        runtime_trusted_proxies => _env_value(
            $environment,
            'GPFORUM_RUNTIME_TRUSTED_PROXIES',
            $DEFAULT_RUNTIME_TRUSTED_PROXIES
        ),
        runtime_pid_file => _env_value(
            $environment, 'GPFORUM_RUNTIME_PID_FILE',
            $DEFAULT_RUNTIME_PID_FILE
        ),
        os_reuseport => _env_value(
            $environment, 'GPFORUM_OS_REUSEPORT',
            $DEFAULT_OS_FEATURE_SETTING
        ),
        os_sendfile => _env_value(
            $environment, 'GPFORUM_OS_SENDFILE',
            $DEFAULT_OS_FEATURE_SETTING
        ),
        os_worker_priority => _env_value(
            $environment, 'GPFORUM_OS_WORKER_PRIORITY',
            $DEFAULT_OS_FEATURE_SETTING
        ),
        os_static_xsendfile => _env_value(
            $environment, 'GPFORUM_OS_STATIC_XSENDFILE',
            $DEFAULT_OS_FEATURE_SETTING
        ),
        os_affinity => _env_value(
            $environment, 'GPFORUM_OS_AFFINITY', $DEFAULT_OS_AFFINITY
        ),
        os_min_recommended_workers => _env_integer(
            $environment, 'GPFORUM_OS_MIN_RECOMMENDED_WORKERS',
            $DEFAULT_OS_MIN_WORKERS
        ),
        os_max_open_file_descriptors => _env_integer(
            $environment, 'GPFORUM_OS_MAX_OPEN_FILE_DESCRIPTORS',
            $DEFAULT_OS_MAX_OPEN_FDS
        ),
        local_cache_max_entries => _env_integer(
            $environment,
            'GPFORUM_LOCAL_CACHE_MAX_ENTRIES',
            $DEFAULT_LOCAL_CACHE_MAX_ENTRIES
        ),
        category_cache_ttl_seconds => _env_integer(
            $environment, 'GPFORUM_CATEGORY_CACHE_TTL_SECONDS',
            $DEFAULT_CATEGORY_CACHE_TTL
        ),
        realtime_listener_enabled => _env_integer(
            $environment, 'GPFORUM_REALTIME_LISTENER_ENABLED',
            $DEFAULT_REALTIME_LISTENER
        ),
        realtime_listener_poll_interval_seconds => _env_integer(
            $environment,
            'GPFORUM_REALTIME_LISTENER_POLL_INTERVAL_SECONDS',
            $DEFAULT_REALTIME_POLL_SECONDS
        ),
        realtime_listener_reconnect_backoff_seconds => _env_integer(
            $environment, 'GPFORUM_REALTIME_LISTENER_RECONNECT_BACKOFF_SECONDS',
            $DEFAULT_REALTIME_BACKOFF
        ),
        realtime_listener_heartbeat_interval_seconds => _env_integer(
            $environment,
            'GPFORUM_REALTIME_LISTENER_HEARTBEAT_INTERVAL_SECONDS',
            $DEFAULT_REALTIME_HEARTBEAT
        ),
        minion_enabled => _env_integer(
            $environment, 'GPFORUM_MINION_ENABLED', $DEFAULT_MINION_ENABLED
        ),
        minion_pg_url => _env_value(
            $environment, 'GPFORUM_MINION_PG_URL', $DEFAULT_MINION_PG_URL
        ),
        metrics_token => _env_value(
            $environment, 'GPFORUM_METRICS_TOKEN', $DEFAULT_METRICS_TOKEN
        ),
        previous_metrics_tokens =>
          _env_csv( $environment, 'GPFORUM_METRICS_TOKENS' ),
        glifistore_url                 => _env_glifistore_url($environment),
        session_touch_interval_seconds => _env_integer(
            $environment,
            'GPFORUM_SESSION_TOUCH_INTERVAL_SECONDS',
            $DEFAULT_SESSION_TOUCH_INTERVAL
        ),
        mail_transport => _env_value(
            $environment,
            'GPFORUM_MAIL_TRANSPORT',
            _default_mail_transport(
                _env_value( $environment, 'GPFORUM_ENV', $DEFAULT_ENVIRONMENT )
            )
        ),
        mail_from =>
          _env_value( $environment, 'GPFORUM_MAIL_FROM', $DEFAULT_MAIL_FROM ),
        smtp_host =>
          _env_value( $environment, 'GPFORUM_SMTP_HOST', $DEFAULT_SMTP_HOST ),
        smtp_port =>
          _env_integer( $environment, 'GPFORUM_SMTP_PORT', $DEFAULT_SMTP_PORT ),
        smtp_username => _env_value(
            $environment, 'GPFORUM_SMTP_USERNAME', $DEFAULT_SMTP_USERNAME
        ),
        smtp_password => _env_value(
            $environment, 'GPFORUM_SMTP_PASSWORD', $DEFAULT_SMTP_PASSWORD
        ),
        smtp_ssl =>
          _env_integer( $environment, 'GPFORUM_SMTP_SSL', $DEFAULT_SMTP_SSL ),
        antivirus => _env_value(
            $environment,
            'GPFORUM_ANTIVIRUS',
            _default_antivirus(
                _env_value( $environment, 'GPFORUM_ENV', $DEFAULT_ENVIRONMENT )
            )
        ),
        antivirus_socket =>
          _env_value( $environment, 'GPFORUM_ANTIVIRUS_SOCKET', q{} ),
        antivirus_command => [
            grep { length } split /\s+/msx,
            _env_value( $environment, 'GPFORUM_ANTIVIRUS_COMMAND', q{} )
        ],
        antivirus_timeout_seconds => _env_integer(
            $environment,
            'GPFORUM_ANTIVIRUS_TIMEOUT_SECONDS',
            _default_antivirus_timeout(
                _env_value(
                    $environment,
                    'GPFORUM_ANTIVIRUS',
                    _default_antivirus(
                        _env_value(
                            $environment, 'GPFORUM_ENV',
                            $DEFAULT_ENVIRONMENT
                        )
                    )
                )
            )
        ),
    );

    $self->validate;

    return $self;
}

sub validate ($self) {
    _require_non_empty( 'environment',    $self->environment );
    _require_non_empty( 'log_level',      $self->log_level );
    _require_non_empty( 'default_locale', $self->default_locale );
    _require_theme( $self->default_theme );
    _require_timezone( $self->default_timezone );
    _require_non_empty( 'public_base_url', $self->public_base_url );
    _require_non_empty( 'session_secret',  $self->session_secret );
    _require_non_empty( 'database_dsn',    $self->database_dsn );
    _require_non_empty( 'database_user',   $self->database_user );
    $self->_validate_database_timeouts;
    _require_positive_integer( 'search_candidate_limit',
        $self->search_candidate_limit );
    _require_process_count( 'web_processes',      $self->web_processes );
    _require_process_count( 'worker_processes',   $self->worker_processes );
    _require_process_count( 'realtime_processes', $self->realtime_processes );
    _require_non_empty( 'runtime_listen',   $self->runtime_listen );
    _require_non_empty( 'runtime_pid_file', $self->runtime_pid_file );
    _require_runtime_worker_policy( $self->runtime_worker_policy );
    _require_positive_integer( 'runtime_max_web_per_cpu',
        $self->runtime_max_web_per_cpu );
    _require_positive_integer( 'runtime_backlog',  $self->runtime_backlog );
    _require_positive_integer( 'runtime_clients',  $self->runtime_clients );
    _require_positive_integer( 'runtime_requests', $self->runtime_requests );
    _require_positive_integer( 'runtime_keep_alive',
        $self->runtime_keep_alive );
    _require_positive_integer( 'runtime_inactivity',
        $self->runtime_inactivity );
    _require_positive_integer( 'runtime_graceful_timeout',
        $self->runtime_graceful_timeout );
    _require_positive_integer( 'runtime_heartbeat_interval',
        $self->runtime_heartbeat_interval );
    _require_positive_integer( 'runtime_heartbeat_timeout',
        $self->runtime_heartbeat_timeout );
    _require_positive_integer( 'runtime_upgrade_timeout',
        $self->runtime_upgrade_timeout );
    _require_positive_integer( 'runtime_spare_processes',
        $self->runtime_spare_processes );
    _require_boolean_integer( 'runtime_proxy', $self->runtime_proxy );
    croak 'runtime_trusted_proxies must name at least one address'
      if $self->runtime_proxy && !@{ $self->runtime_trusted_proxy_list };
    _require_os_feature_setting( 'os_reuseport', $self->os_reuseport );
    _require_os_feature_setting( 'os_sendfile',  $self->os_sendfile );
    _require_os_feature_setting( 'os_worker_priority',
        $self->os_worker_priority );
    _require_os_feature_setting( 'os_static_xsendfile',
        $self->os_static_xsendfile );
    _require_os_affinity( $self->os_affinity );
    _require_os_threshold( 'os_min_recommended_workers',
        $self->os_min_recommended_workers );
    _require_os_threshold( 'os_max_open_file_descriptors',
        $self->os_max_open_file_descriptors );
    _require_positive_integer( 'local_cache_max_entries',
        $self->local_cache_max_entries );
    _require_positive_integer( 'category_cache_ttl_seconds',
        $self->category_cache_ttl_seconds );
    _require_boolean_integer( 'realtime_listener_enabled',
        $self->realtime_listener_enabled );
    _require_positive_integer(
        'realtime_listener_poll_interval_seconds',
        $self->realtime_listener_poll_interval_seconds
    );
    _require_positive_integer(
        'realtime_listener_reconnect_backoff_seconds',
        $self->realtime_listener_reconnect_backoff_seconds
    );
    _require_positive_integer(
        'realtime_listener_heartbeat_interval_seconds',
        $self->realtime_listener_heartbeat_interval_seconds
    );
    _require_boolean_integer( 'minion_enabled', $self->minion_enabled );
    _require_non_empty( 'minion_pg_url', $self->minion_pg_url )
      if $self->minion_enabled;
    _require_glifistore_url( $self->glifistore_url );
    _require_configured_glifistore($self);
    _require_positive_integer(
        'session_touch_interval_seconds',
        $self->session_touch_interval_seconds
    );
    $self->_validate_mail;
    $self->_validate_antivirus;
    $self->_validate_rotated_secrets;

    return $self;
}

sub requires_glifistore ($self) {
    return $self->environment_requires_glifistore( $self->environment );
}

sub requires_secure_transport ($self) {
    return _requires_rotated_secret( $self->environment );
}

sub signing_secrets ($self) {
    return _unique_head( $self->session_secret,
        $self->previous_session_secrets );
}

sub accepted_metrics_tokens ($self) {
    return _unique_head( $self->metrics_token, $self->previous_metrics_tokens );
}

sub environment_requires_glifistore ( $, $environment ) {
    return _environment_requires_glifistore($environment);
}

sub os_feature_settings ($self) {
    return {
        reuseport        => $self->os_reuseport,
        sendfile         => $self->os_sendfile,
        worker_priority  => $self->os_worker_priority,
        static_xsendfile => $self->os_static_xsendfile,
        affinity         => $self->os_affinity,
    };
}

sub os_preflight_settings ($self) {
    return {
        min_recommended_workers   => $self->os_min_recommended_workers,
        max_open_file_descriptors => $self->os_max_open_file_descriptors,
    };
}

# The addresses whose X-Forwarded-For is believed. Only the loopback by
# default: the shipped proxies run on the same host. Believing any sender, as
# before, let a client that reached the application directly name its own
# address, and with it its rate-limit bucket.
sub runtime_trusted_proxy_list ($self) {
    return [ _csv_items( $self->runtime_trusted_proxies ) ];
}

sub runtime_listen_locations ($self) {
    return [ grep { length }
          map { _trim($_) } split /,/msx,
        $self->runtime_listen ];
}

sub database_connect_info ($self) {
    return (
        $self->database_dsn,      $self->database_user,
        $self->database_password, $self->_database_dbi_attributes,
    );
}

sub _database_dbi_attributes ($self) {
    return {
        AutoCommit     => 1,
        RaiseError     => 1,
        PrintError     => 0,
        on_connect_do  => $self->_database_session_settings,
        pg_enable_utf8 => 1,
    };
}

sub _database_session_settings ($self) {
    return [
        _timeout_setting(
            'statement_timeout', $self->database_statement_timeout_ms
        ),
        _timeout_setting(
            'idle_in_transaction_session_timeout',
            $self->database_idle_in_transaction_timeout_ms
        ),
        _timeout_setting( 'lock_timeout', $self->database_lock_timeout_ms ),
        $SET_APPLICATION_NAME,
        $SET_MESSAGE_LOCALE,
        $SET_SEARCH_SIMILARITY,
    ];
}

sub _timeout_setting ( $name, $milliseconds ) {
    return "SET $name = $milliseconds";
}

sub _validate_database_timeouts ($self) {
    _require_non_negative_integer( 'database_statement_timeout_ms',
        $self->database_statement_timeout_ms );
    _require_non_negative_integer(
        'database_idle_in_transaction_timeout_ms',
        $self->database_idle_in_transaction_timeout_ms
    );
    _require_non_negative_integer( 'database_lock_timeout_ms',
        $self->database_lock_timeout_ms );
    _require_non_negative_integer( 'search_statement_timeout_ms',
        $self->search_statement_timeout_ms );

    return;
}

sub _require_runtime_worker_policy ($value) {
    croak 'runtime_worker_policy must be configured or cap-to-cpu'
      if !exists $VALID_RUNTIME_WORKER_POLICY{$value};

    return;
}

sub _require_timezone ($value) {
    croak 'default_timezone must be an IANA time zone such as Europe/Rome'
      if !DateTime::TimeZone->is_valid_name($value);

    return;
}

sub _require_theme ($value) {
    croak 'default_theme must be default, dark, or high_contrast'
      if !exists $VALID_THEME{$value};

    return;
}

sub _require_boolean_integer ( $name, $value ) {
    croak "$name must be 0 or 1"
      if $value != 0 && $value != 1;

    return;
}

sub _trim ($value) {
    $value =~ s/\A\s+|\s+\z//gmsx;
    return $value;
}

sub _env_value ( $environment, $name, $default ) {
    return
      exists $environment->{$name} && length $environment->{$name}
      ? $environment->{$name}
      : $default;
}

sub _env_csv ( $environment, $name ) {
    return [ _csv_items( _env_value( $environment, $name, q{} ) ) ];
}

sub _csv_items ($raw) {
    return grep { length } map { _trim($_) } split /,/msx, $raw;
}

sub _unique_head ( $first, $rest ) {
    return _collect_unique( $first, $rest || [] );
}

sub _collect_unique ( $first, $rest ) {
    my %seen = ( $first => 1 );

    return [ $first, _unseen_items( $rest, \%seen ) ];
}

sub _unseen_items ( $rest, $seen ) {
    my @items;
    for my $item ( @{$rest} ) {
        if ( _take_unseen( $item, $seen ) ) {
            push @items, $item;
        }
    }

    return @items;
}

sub _take_unseen ( $item, $seen ) {
    if ( !defined $item || !length $item ) {
        return 0;
    }
    if ( $seen->{$item} ) {
        return 0;
    }

    $seen->{$item} = 1;

    return 1;
}

sub _env_integer ( $environment, $name, $default ) {
    my $value = _env_value( $environment, $name, $default );

    croak "$name must be an integer"
      if $value !~ /\A [[:digit:]]+ \z/msx;

    return int $value;
}

sub _requires_rotated_secret ($environment) {
    if ( !$environment || !exists $ROTATED_SECRET_ENV{$environment} ) {
        return 0;
    }

    return 1;
}

sub _validate_rotated_secrets ($self) {
    if ( !_requires_rotated_secret( $self->environment ) ) {
        return;
    }

    _require_rotated_session_secret($self);
    _reject_development_previous( $self->previous_session_secrets );
    _require_configured_metrics_token($self);

    return;
}

sub _require_rotated_session_secret ($self) {
    if ( $self->session_secret eq $DEFAULT_SESSION_SECRET ) {
        croak 'production requires GPFORUM_SESSION_SECRET';
    }

    return;
}

sub _require_configured_metrics_token ($self) {
    my $token = $self->metrics_token;
    if ( !defined $token || !length $token ) {
        croak 'production requires GPFORUM_METRICS_TOKEN';
    }

    return;
}

sub _reject_development_previous ($secrets) {
    for my $secret ( @{$secrets} ) {
        _reject_development_secret($secret);
    }

    return;
}

sub _reject_development_secret ($secret) {
    if ( defined $secret && $secret eq $DEFAULT_SESSION_SECRET ) {
        croak
          'GPFORUM_SESSION_SECRETS must not include the development default';
    }

    return;
}

sub _require_non_empty ( $name, $value ) {
    croak "$name is required"
      if !defined $value || !length $value;

    return;
}

sub _require_process_count ( $name, $value ) {
    croak "$name must be >= $MINIMUM_PROCESS_COUNT"
      if $value < $MINIMUM_PROCESS_COUNT;

    croak "$name must be <= $MAXIMUM_PROCESS_COUNT"
      if $value > $MAXIMUM_PROCESS_COUNT;

    return;
}

sub _require_os_feature_setting ( $name, $value ) {
    croak "$name must be auto, on, or off"
      if !exists $VALID_OS_FEATURE_SETTING{$value};

    return;
}

sub _require_os_affinity ($value) {
    croak 'os_affinity must be off or manual'
      if !exists $VALID_OS_AFFINITY{$value};

    return;
}

sub _require_os_threshold ( $name, $value ) {
    croak "$name must be >= $MINIMUM_OS_THRESHOLD"
      if $value < $MINIMUM_OS_THRESHOLD;

    return;
}

sub _require_positive_integer ( $name, $value ) {
    croak "$name must be >= 1"
      if $value < 1;

    return;
}

sub _require_non_negative_integer ( $name, $value ) {
    if ( $value < 0 ) {
        croak "$name must be >= 0";
    }

    return;
}

sub _require_configured_glifistore ($self) {
    if ( !$self->requires_glifistore ) {
        return;
    }

    _require_non_empty( 'glifistore_url', $self->glifistore_url );
    return;
}

sub _env_glifistore_url ($environment) {
    my $configured = _configured_glifistore_url($environment);
    if ( defined $configured ) {
        return $configured;
    }

    return _default_glifistore_url($environment);
}

sub _configured_glifistore_url ($environment) {
    if ( !exists $environment->{GPFORUM_GLIFISTORE_URL} ) {
        return;
    }
    if ( !length $environment->{GPFORUM_GLIFISTORE_URL} ) {
        return;
    }

    return $environment->{GPFORUM_GLIFISTORE_URL};
}

sub _default_glifistore_url ($environment) {
    my $name = _env_value( $environment, 'GPFORUM_ENV', $DEFAULT_ENVIRONMENT );
    if ( _environment_requires_glifistore($name) ) {
        return q{};
    }

    return $DEFAULT_GLIFISTORE_URL;
}

sub _environment_requires_glifistore ($environment) {
    if ( !$environment ) {
        return 0;
    }
    if ( !exists $REQUIRES_GLIFISTORE{$environment} ) {
        return 0;
    }

    return 1;
}

sub _validate_mail ($self) {
    _require_non_empty( 'mail_transport', $self->mail_transport );
    _require_mail_transport( $self->mail_transport );
    _require_non_empty( 'mail_from', $self->mail_from );
    _require_positive_integer( 'smtp_port', $self->smtp_port );
    _require_boolean_integer( 'smtp_ssl', $self->smtp_ssl );

    return;
}

sub _require_mail_transport ($value) {
    if ( exists $VALID_MAIL_TRANSPORT{$value} ) {
        return;
    }

    croak 'mail_transport must be test, smtp, or sendmail';
}

sub _validate_antivirus ($self) {
    if ( !exists $VALID_ANTIVIRUS{ $self->antivirus } ) {
        croak 'antivirus must be clamd, command, or none';
    }
    if ( $self->antivirus eq 'command' && !@{ $self->antivirus_command } ) {
        croak 'antivirus command requires GPFORUM_ANTIVIRUS_COMMAND';
    }
    _require_positive_integer( 'antivirus_timeout_seconds',
        $self->antivirus_timeout_seconds );

    return;
}

# Staging and production scan uploads with the system's clamd unless the
# operator says otherwise; development and test do not assume one is
# installed.
sub _default_antivirus ($environment) {
    return 'clamd' if _requires_rotated_secret($environment);

    return $DEFAULT_ANTIVIRUS;
}

# A resident clamd answers in well under a second. clamscan, run per file,
# loads its whole signature database first, which alone can take most of 30
# seconds on a small server.
sub _default_antivirus_timeout ($engine) {
    return $engine eq 'command'
      ? $DEFAULT_COMMAND_TIMEOUT
      : $DEFAULT_ANTIVIRUS_TIMEOUT;
}

sub _default_mail_transport ($environment) {
    if ( _requires_rotated_secret($environment) ) {
        return 'sendmail';
    }

    return $DEFAULT_MAIL_TRANSPORT;
}

sub _require_glifistore_url ($value) {
    if ( !defined $value ) {
        return;
    }
    if ( !length $value ) {
        return;
    }
    if ( $value =~ $GLIFISTORE_TCP_URL ) {
        return;
    }
    if ( $value =~ $GLIFISTORE_UNIX_URL ) {
        return;
    }

    croak 'glifistore_url must be tcp://host:port, unix://path, or host:port';
}

1;

__END__

=head1 NAME

GPForum::Config - Environment-backed configuration object.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $config = GPForum::Config->from_environment;

=head1 DESCRIPTION

Loads and validates milestone-zero configuration, including the multi-process
runtime profile.

=head1 SUBROUTINES/METHODS

=head2 from_environment

Builds configuration from an environment hash.

=head2 validate

Validates required configuration and process bounds. Staging and
production profiles require C<glifistore_url>.

=head2 requires_glifistore

True when the configured environment must set a GlifiStore URL.

=head2 requires_secure_transport

True for staging and production profiles. Those environments require a
rotated session secret, Secure cookies, and HSTS.

=head2 signing_secrets

Returns the Mojolicious secret list. The current session secret is first
and signs new cookies. Previous secrets from
C<GPFORUM_SESSION_SECRETS> still validate existing cookies.

=head2 accepted_metrics_tokens

Returns the current metrics token followed by previous tokens from
C<GPFORUM_METRICS_TOKENS>. Scrapers may present either during rotation.
Staging and production refuse to start without C<GPFORUM_METRICS_TOKEN>, so
the list is never empty there and C</metrics> cannot fail open. Development
and test may leave it unset and keep C</metrics> unauthenticated.

=head2 environment_requires_glifistore

Class helper for the same GlifiStore requirement check.

=head2 runtime_trusted_proxy_list

The addresses and networks (C<GPFORUM_RUNTIME_TRUSTED_PROXIES>, comma
separated; C<127.0.0.1,::1> by default) whose C<X-Forwarded-For> Hypnotoad
believes when C<runtime_proxy> is on.

=head2 database_connect_info

Returns DBI connection arguments for DBIx::Class. Session
C<statement_timeout>, C<idle_in_transaction_session_timeout>,
C<lock_timeout>, and C<application_name> are applied on connect. Zero
milliseconds disables that PostgreSQL timeout. C<gpforum-migrate --apply>
clears C<statement_timeout> after connect so DDL is not capped at the web
budget.

=head1 DIAGNOSTICS

Throws exceptions for missing values, invalid integers, and unsafe production
secrets.

=head1 CONFIGURATION AND ENVIRONMENT

Reads C<GPFORUM_*> environment variables, including PostgreSQL connection
settings (C<GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS>,
C<GPFORUM_DATABASE_IDLE_IN_TRANSACTION_TIMEOUT_MS>,
C<GPFORUM_DATABASE_LOCK_TIMEOUT_MS>), search's own statement timeout
(C<GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS>, 2000 by default; zero leaves search
under C<GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS>) and the number of newest
matches it ranks (C<GPFORUM_SEARCH_CANDIDATE_LIMIT>, 1000 by default, at least
1), session rotation
(C<GPFORUM_SESSION_SECRET>, comma-separated
C<GPFORUM_SESSION_SECRETS>), metrics scrape tokens
(C<GPFORUM_METRICS_TOKEN>, comma-separated C<GPFORUM_METRICS_TOKENS>),
and mail delivery (C<GPFORUM_MAIL_TRANSPORT>, C<GPFORUM_MAIL_FROM>,
and optional SMTP host, port, credentials, and TLS). Development and test
default to the C<test> transport; staging and production default to
C<sendmail>. Upload scanning (C<GPFORUM_ANTIVIRUS>: C<clamd>, C<command> or
C<none>, with C<GPFORUM_ANTIVIRUS_SOCKET>, C<GPFORUM_ANTIVIRUS_COMMAND> and
C<GPFORUM_ANTIVIRUS_TIMEOUT_SECONDS>) defaults to C<clamd> in staging and
production and C<none> elsewhere. Staging and production reject the development session secret
in both the current secret and C<GPFORUM_SESSION_SECRETS>, and require a
non-empty C<GPFORUM_METRICS_TOKEN> so the C</metrics> scrape endpoint is
never left unauthenticated.

=head1 DEPENDENCIES

Uses L<Carp>, L<Const::Fast>, and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The first milestone validates database connection shape but does not connect
unless a caller asks the schema layer to do so.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
