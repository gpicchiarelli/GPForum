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
const my $DEFAULT_DATABASE_USER      => 'gpforum';
const my $DEFAULT_DATABASE_PASSWORD  => q{};
const my $DEFAULT_WEB_PROCESSES      => 4;
const my $DEFAULT_WORKER_PROCESSES   => 2;
const my $DEFAULT_REALTIME_PROCESSES => 1;
const my $MINIMUM_PROCESS_COUNT      => 1;
const my $MAXIMUM_PROCESS_COUNT      => 512;

has environment        => sub { return $DEFAULT_ENVIRONMENT; };
has log_level          => sub { return $DEFAULT_LOG_LEVEL; };
has public_base_url    => sub { return $DEFAULT_PUBLIC_BASE_URL; };
has session_secret     => sub { return $DEFAULT_SESSION_SECRET; };
has database_dsn       => sub { return $DEFAULT_DATABASE_DSN; };
has database_user      => sub { return $DEFAULT_DATABASE_USER; };
has database_password  => sub { return $DEFAULT_DATABASE_PASSWORD; };
has web_processes      => sub { return $DEFAULT_WEB_PROCESSES; };
has worker_processes   => sub { return $DEFAULT_WORKER_PROCESSES; };
has realtime_processes => sub { return $DEFAULT_REALTIME_PROCESSES; };

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

    if (   $self->environment eq 'production'
        && $self->session_secret eq $DEFAULT_SESSION_SECRET )
    {
        croak 'production requires GPFORUM_SESSION_SECRET';
    }

    return $self;
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
