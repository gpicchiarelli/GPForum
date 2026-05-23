package GPForum::Config;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $DEFAULT_ENVIRONMENT     => 'development';
const my $DEFAULT_LOG_LEVEL       => 'debug';
const my $DEFAULT_PUBLIC_BASE_URL => 'http://127.0.0.1:3000';
const my $DEFAULT_SESSION_SECRET  => 'gpforum-development-secret-change-me';
const my $DEFAULT_DATABASE_DSN =>
  'dbi:Pg:dbname=gpforum;host=127.0.0.1;port=5432';
const my $DEFAULT_DATABASE_USER           => 'gpforum';
const my $DEFAULT_DATABASE_PASSWORD       => q{};
const my $DEFAULT_WEB_PROCESSES           => 4;
const my $DEFAULT_WORKER_PROCESSES        => 2;
const my $DEFAULT_REALTIME_PROCESSES      => 1;
const my $DEFAULT_OS_FEATURE_SETTING      => 'auto';
const my $DEFAULT_OS_AFFINITY             => 'off';
const my $DEFAULT_OS_MIN_WORKERS          => 1;
const my $DEFAULT_OS_MAX_OPEN_FDS         => 1024;
const my $DEFAULT_LOCAL_CACHE_MAX_ENTRIES => 512;
const my $DEFAULT_CATEGORY_CACHE_TTL      => 30;
const my $MINIMUM_PROCESS_COUNT           => 1;
const my $MAXIMUM_PROCESS_COUNT           => 512;
const my $MINIMUM_OS_THRESHOLD            => 1;
const my %VALID_OS_FEATURE_SETTING        => map { $_ => 1 } qw(auto on off);
const my %VALID_OS_AFFINITY               => map { $_ => 1 } qw(off manual);

has environment                  => sub { return $DEFAULT_ENVIRONMENT; };
has log_level                    => sub { return $DEFAULT_LOG_LEVEL; };
has public_base_url              => sub { return $DEFAULT_PUBLIC_BASE_URL; };
has session_secret               => sub { return $DEFAULT_SESSION_SECRET; };
has database_dsn                 => sub { return $DEFAULT_DATABASE_DSN; };
has database_user                => sub { return $DEFAULT_DATABASE_USER; };
has database_password            => sub { return $DEFAULT_DATABASE_PASSWORD; };
has web_processes                => sub { return $DEFAULT_WEB_PROCESSES; };
has worker_processes             => sub { return $DEFAULT_WORKER_PROCESSES; };
has realtime_processes           => sub { return $DEFAULT_REALTIME_PROCESSES; };
has os_reuseport                 => sub { return $DEFAULT_OS_FEATURE_SETTING; };
has os_sendfile                  => sub { return $DEFAULT_OS_FEATURE_SETTING; };
has os_worker_priority           => sub { return $DEFAULT_OS_FEATURE_SETTING; };
has os_static_xsendfile          => sub { return $DEFAULT_OS_FEATURE_SETTING; };
has os_affinity                  => sub { return $DEFAULT_OS_AFFINITY; };
has os_min_recommended_workers   => sub { return $DEFAULT_OS_MIN_WORKERS; };
has os_max_open_file_descriptors => sub { return $DEFAULT_OS_MAX_OPEN_FDS; };
has local_cache_max_entries => sub { return $DEFAULT_LOCAL_CACHE_MAX_ENTRIES; };
has category_cache_ttl_seconds => sub { return $DEFAULT_CATEGORY_CACHE_TTL; };

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
    );

    $self->validate;

    return $self;
}

sub validate {
    my ($self) = @_;

    _require_non_empty( 'environment',     $self->environment );
    _require_non_empty( 'log_level',       $self->log_level );
    _require_non_empty( 'public_base_url', $self->public_base_url );
    _require_non_empty( 'session_secret',  $self->session_secret );
    _require_non_empty( 'database_dsn',    $self->database_dsn );
    _require_non_empty( 'database_user',   $self->database_user );
    _require_process_count( 'web_processes',      $self->web_processes );
    _require_process_count( 'worker_processes',   $self->worker_processes );
    _require_process_count( 'realtime_processes', $self->realtime_processes );
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
