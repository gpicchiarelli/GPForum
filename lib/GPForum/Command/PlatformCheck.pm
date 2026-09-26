# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::PlatformCheck;

use strict;
use warnings;

use Carp       qw(croak);
use List::Util qw(any);
use Mojo::Base -base, -signatures;

use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Runtime;
use GPForum::Service::Operations::OSPreflight;
use GPForum::Service::Operations::Profile;
use GPForum::Service::Operations::QueryBudget;

our $VERSION = '0.001';

has config  => undef;
has runtime => undef;
has schema  => undef;

sub run ( $self, @arguments ) {
    my $command = _command(@arguments);

    return GPForum::Command::Usage->help( \*STDOUT, _usage() )
      if $command eq '--help' || $command eq '-h';

    my $method = _method_for($command);
    return GPForum::Command::Usage->error( "unknown option $command", _usage() )
      if !defined $method;

    return $self->$method();
}

sub local_check ($self) {
    return $self->_platform_check( { include_db => 0, strict => 0 } );
}

sub strict_local_check ($self) {
    return $self->_platform_check( { include_db => 0, strict => 1 } );
}

sub with_db_check ($self) {
    return $self->_platform_check( { include_db => 1, strict => 0 } );
}

sub strict_with_db_check ($self) {
    return $self->_platform_check( { include_db => 1, strict => 1 } );
}

sub _platform_check ( $self, $options ) {
    my @checks = ( $self->_os_preflight_check, $self->_profile_check );
    if ( $options->{include_db} ) {
        push @checks, $self->_query_budget_drift_check;
    }

    for my $check (@checks) {
        print "$check->{name} status=$check->{status}\n"
          or croak 'failed to write platform check';
    }

    return _exit_status( \@checks, $options->{strict} );
}

sub _os_preflight_check ($self) {
    my $report = GPForum::Service::Operations::OSPreflight->new(
        runtime => $self->_runtime )->check;

    return {
        name   => 'os_preflight',
        status => $report->{status},
        report => $report,
    };
}

sub _profile_check ($self) {
    my $result =
      GPForum::Service::Operations::Profile->new->evaluate( $self->_config );

    return {
        name   => 'operational_profile',
        report => $result,
        status => $result->{ok} ? 'ok' : 'fail',
    };
}

sub _query_budget_drift_check ($self) {
    my $report =
      GPForum::Service::Operations::QueryBudget->new( schema => $self->_schema )
      ->drift_report;

    return {
        name   => 'query_budget_drift',
        status => $report->{status},
        report => $report,
    };
}

sub _config ($self) {
    if ( $self->config ) {
        return $self->config;
    }

    return GPForum::Config->from_environment;
}

sub _runtime ($self) {
    if ( $self->runtime ) {
        return $self->runtime;
    }

    return GPForum::Runtime->from_config( $self->_config );
}

sub _schema ($self) {
    if ( $self->schema ) {
        return $self->schema;
    }

    require GPForum::Schema;
    return GPForum::Schema->connect_from_config( $self->_config );
}

sub _exit_status ( $checks, $strict ) {
    return 1 if any { $_->{status} eq 'fail' } @{$checks};
    return 0 if !$strict;

    return ( any { $_->{status} ne 'ok' } @{$checks} ) ? 1 : 0;
}

sub _command (@arguments) {
    my $command = shift @arguments;
    return defined $command ? $command : '--local';
}

sub _method_for ($command) {
    return 'local_check'          if $command eq '--local';
    return 'strict_local_check'   if $command eq '--strict-local';
    return 'with_db_check'        if $command eq '--with-db';
    return 'strict_with_db_check' if $command eq '--strict-with-db';

    my $undefined;
    return $undefined;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return <<'USAGE';
Usage: bin/gpforum-platform-check --local|--strict-local|--with-db|--strict-with-db

Reports whether this host satisfies the platform prerequisites.

  --local             check what can be checked without a database
  --strict-local      as --local, but warnings fail the run
  --with-db           also check the database connection and settings
  --strict-with-db    as --with-db, but warnings fail the run
  --help              show this help

Exit status: 0 success, 1 a check failed, 2 usage error.
USAGE
}

1;
