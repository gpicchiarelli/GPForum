package GPForum::Config;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $DEFAULT_ENVIRONMENT     => 'development';
const my $DEFAULT_LOG_LEVEL       => 'debug';
const my $DEFAULT_LOCALE          => 'en';
const my $DEFAULT_THEME           => 'default';
const my $DEFAULT_PUBLIC_BASE_URL => 'http://127.0.0.1:3000';
const my $DEFAULT_SESSION_SECRET  => 'gpforum-development-secret-change-me';
const my $DEFAULT_DATABASE_DSN =>
  'dbi:Pg:dbname=gpforum;host=127.0.0.1;port=5432';
const my $DEFAULT_DATABASE_USER           => 'gpforum';
const my $DEFAULT_DATABASE_PASSWORD       => q{};
const my $DEFAULT_WEB_PROCESSES           => 4;
const my $DEFAULT_WORKER_PROCESSES        => 2;
const my $DEFAULT_REALTIME_PROCESSES      => 1;
const my $DEFAULT_RUNTIME_LISTEN          => 'http://*:8080';
const my $DEFAULT_RUNTIME_WORKER_POLICY   => 'cap-to-cpu';
const my $DEFAULT_RUNTIME_MAX_WEB_PER_CPU => 2;
const my $DEFAULT_RUNTIME_BACKLOG         => 128;
const my $DEFAULT_RUNTIME_CLIENTS         => 100;
const my $DEFAULT_RUNTIME_REQUESTS        => 100;
const my $DEFAULT_RUNTIME_KEEP_ALIVE      => 10;
const my $DEFAULT_RUNTIME_INACTIVITY      => 30;
const my $DEFAULT_RUNTIME_GRACEFUL        => 15;
const my $DEFAULT_RUNTIME_HEARTBEAT_INT   => 3;
const my $DEFAULT_RUNTIME_HEARTBEAT_TO    => 2;
const my $DEFAULT_RUNTIME_UPGRADE         => 45;
const my $DEFAULT_RUNTIME_SPARE           => 1;
const my $DEFAULT_RUNTIME_PROXY           => 1;
const my $DEFAULT_RUNTIME_PID_FILE        => 'hypnotoad.pid';
const my $DEFAULT_OS_FEATURE_SETTING      => 'auto';
const my $DEFAULT_OS_AFFINITY             => 'off';
const my $DEFAULT_OS_MIN_WORKERS          => 1;
const my $DEFAULT_OS_MAX_OPEN_FDS         => 1024;
const my $DEFAULT_LOCAL_CACHE_MAX_ENTRIES => 512;
const my $DEFAULT_CATEGORY_CACHE_TTL      => 30;
const my $DEFAULT_REALTIME_LISTENER       => 0;
const my $DEFAULT_REALTIME_POLL_SECONDS   => 1;
const my $DEFAULT_REALTIME_BACKOFF        => 5;
const my $DEFAULT_REALTIME_HEARTBEAT      => 30;
const my $DEFAULT_MINION_ENABLED          => 0;
const my $DEFAULT_MINION_PG_URL           => q{};
const my $MINIMUM_PROCESS_COUNT           => 1;
const my $MAXIMUM_PROCESS_COUNT           => 512;
const my $MINIMUM_OS_THRESHOLD            => 1;
const my %VALID_OS_FEATURE_SETTING        => map { $_ => 1 } qw(auto on off);
const my %VALID_OS_AFFINITY               => map { $_ => 1 } qw(off manual);
const my %VALID_RUNTIME_WORKER_POLICY => map { $_ => 1 }
  qw(configured cap-to-cpu);
const my %VALID_THEME => map { $_ => 1 } qw(default dark high_contrast);

has environment             => sub { return $DEFAULT_ENVIRONMENT; };
has log_level               => sub { return $DEFAULT_LOG_LEVEL; };
has default_locale          => sub { return $DEFAULT_LOCALE; };
has default_theme           => sub { return $DEFAULT_THEME; };
has public_base_url         => sub { return $DEFAULT_PUBLIC_BASE_URL; };
has session_secret          => sub { return $DEFAULT_SESSION_SECRET; };
has database_dsn            => sub { return $DEFAULT_DATABASE_DSN; };
has database_user           => sub { return $DEFAULT_DATABASE_USER; };
has database_password       => sub { return $DEFAULT_DATABASE_PASSWORD; };
has web_processes           => sub { return $DEFAULT_WEB_PROCESSES; };
has worker_processes        => sub { return $DEFAULT_WORKER_PROCESSES; };
has realtime_processes      => sub { return $DEFAULT_REALTIME_PROCESSES; };
has runtime_listen          => sub { return $DEFAULT_RUNTIME_LISTEN; };
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
has runtime_heartbeat_timeout  => sub { return $DEFAULT_RUNTIME_HEARTBEAT_TO; };
has runtime_upgrade_timeout    => sub { return $DEFAULT_RUNTIME_UPGRADE; };
has runtime_spare_processes    => sub { return $DEFAULT_RUNTIME_SPARE; };
has runtime_proxy              => sub { return $DEFAULT_RUNTIME_PROXY; };
has runtime_pid_file           => sub { return $DEFAULT_RUNTIME_PID_FILE; };
has os_reuseport               => sub { return $DEFAULT_OS_FEATURE_SETTING; };
has os_sendfile                => sub { return $DEFAULT_OS_FEATURE_SETTING; };
has os_worker_priority         => sub { return $DEFAULT_OS_FEATURE_SETTING; };
has os_static_xsendfile        => sub { return $DEFAULT_OS_FEATURE_SETTING; };
has os_affinity                => sub { return $DEFAULT_OS_AFFINITY; };
has os_min_recommended_workers => sub { return $DEFAULT_OS_MIN_WORKERS; };
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
has minion_enabled => sub { return $DEFAULT_MINION_ENABLED; };
has minion_pg_url  => sub { return $DEFAULT_MINION_PG_URL; };

sub from_environment {
    my ( $class, $environment ) = @_;
    if ( !defined $environment ) {
        $environment = \%ENV;
    }

    my $self = $class->new(
        environment =>
          _env_value( $environment, 'GPFORUM_ENV', $DEFAULT_ENVIRONMENT ),
        log_level =>
          _env_value( $environment, 'GPFORUM_LOG_LEVEL', $DEFAULT_LOG_LEVEL ),
        default_locale =>
          _env_value( $environment, 'GPFORUM_DEFAULT_LOCALE', $DEFAULT_LOCALE ),
        default_theme =>
          _env_value( $environment, 'GPFORUM_DEFAULT_THEME', $DEFAULT_THEME ),
        public_base_url => _env_value(
            $environment, 'GPFORUM_PUBLIC_BASE_URL',
            $DEFAULT_PUBLIC_BASE_URL
        ),
        session_secret => _env_value(
            $environment, 'GPFORUM_SESSION_SECRET', $DEFAULT_SESSION_SECRET
        ),
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
    );

    $self->validate;

    return $self;
}

sub validate {
    my ($self) = @_;

    _require_non_empty( 'environment',    $self->environment );
    _require_non_empty( 'log_level',      $self->log_level );
    _require_non_empty( 'default_locale', $self->default_locale );
    _require_theme( $self->default_theme );
    _require_non_empty( 'public_base_url', $self->public_base_url );
    _require_non_empty( 'session_secret',  $self->session_secret );
    _require_non_empty( 'database_dsn',    $self->database_dsn );
    _require_non_empty( 'database_user',   $self->database_user );
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

    if (   $self->environment eq 'production'
        && $self->session_secret eq $DEFAULT_SESSION_SECRET )
    {
        croak 'production requires GPFORUM_SESSION_SECRET';
    }

    return $self;
}

sub os_feature_settings {
    my ($self) = @_;

    return {
        reuseport        => $self->os_reuseport,
        sendfile         => $self->os_sendfile,
        worker_priority  => $self->os_worker_priority,
        static_xsendfile => $self->os_static_xsendfile,
        affinity         => $self->os_affinity,
    };
}

sub os_preflight_settings {
    my ($self) = @_;

    return {
        min_recommended_workers   => $self->os_min_recommended_workers,
        max_open_file_descriptors => $self->os_max_open_file_descriptors,
    };
}

sub runtime_listen_locations {
    my ($self) = @_;

    return [ grep { length }
          map { _trim($_) } split /,/msx,
        $self->runtime_listen ];
}

sub database_connect_info {
    my ($self) = @_;

    return (
        $self->database_dsn,
        $self->database_user,
        $self->database_password,
        {
            AutoCommit     => 1,
            RaiseError     => 1,
            PrintError     => 0,
            pg_enable_utf8 => 1,
        },
    );
}

sub _require_runtime_worker_policy {
    my ($value) = @_;

    croak 'runtime_worker_policy must be configured or cap-to-cpu'
      if !exists $VALID_RUNTIME_WORKER_POLICY{$value};

    return;
}

sub _require_theme {
    my ($value) = @_;

    croak 'default_theme must be default, dark, or high_contrast'
      if !exists $VALID_THEME{$value};

    return;
}

sub _require_boolean_integer {
    my ( $name, $value ) = @_;

    croak "$name must be 0 or 1"
      if $value != 0 && $value != 1;

    return;
}

sub _trim {
    my ($value) = @_;

    $value =~ s/\A\s+|\s+\z//gmsx;
    return $value;
}

sub _env_value {
    my ( $environment, $name, $default ) = @_;

    return
      exists $environment->{$name} && length $environment->{$name}
      ? $environment->{$name}
      : $default;
}

sub _env_integer {
    my ( $environment, $name, $default ) = @_;

    my $value = _env_value( $environment, $name, $default );

    croak "$name must be an integer"
      if $value !~ /\A [[:digit:]]+ \z/msx;

    return int $value;
}

sub _require_non_empty {
    my ( $name, $value ) = @_;

    croak "$name is required"
      if !defined $value || !length $value;

    return;
}

sub _require_process_count {
    my ( $name, $value ) = @_;

    croak "$name must be >= $MINIMUM_PROCESS_COUNT"
      if $value < $MINIMUM_PROCESS_COUNT;

    croak "$name must be <= $MAXIMUM_PROCESS_COUNT"
      if $value > $MAXIMUM_PROCESS_COUNT;

    return;
}

sub _require_os_feature_setting {
    my ( $name, $value ) = @_;

    croak "$name must be auto, on, or off"
      if !exists $VALID_OS_FEATURE_SETTING{$value};

    return;
}

sub _require_os_affinity {
    my ($value) = @_;

    croak 'os_affinity must be off or manual'
      if !exists $VALID_OS_AFFINITY{$value};

    return;
}

sub _require_os_threshold {
    my ( $name, $value ) = @_;

    croak "$name must be >= $MINIMUM_OS_THRESHOLD"
      if $value < $MINIMUM_OS_THRESHOLD;

    return;
}

sub _require_positive_integer {
    my ( $name, $value ) = @_;

    croak "$name must be >= 1"
      if $value < 1;

    return;
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

Validates required configuration and process bounds.

=head2 database_connect_info

Returns DBI connection arguments for DBIx::Class.

=head1 DIAGNOSTICS

Throws exceptions for missing values, invalid integers, and unsafe production
secrets.

=head1 CONFIGURATION AND ENVIRONMENT

Reads C<GPFORUM_*> environment variables, including PostgreSQL connection
settings.

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
