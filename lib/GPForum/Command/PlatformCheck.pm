package GPForum::Command::PlatformCheck;

use strict;
use warnings;

use Carp       qw(croak);
use List::Util qw(any);
use Mojo::Base -base;

use GPForum::Config;
use GPForum::Runtime;
use GPForum::Service::Operations::OSPreflight;
use GPForum::Service::Operations::Profile;
use GPForum::Service::Operations::QueryBudget;

our $VERSION = '0.001';

has config  => undef;
has runtime => undef;
has schema  => undef;

sub run {
    my ( $self, @arguments ) = @_;

    my $command = _command(@arguments);
    my $method  = _method_for($command);

    croak _usage() if !defined $method;

    return $self->$method();
}

sub local_check {
    my ($self) = @_;

    return $self->_platform_check( { include_db => 0, strict => 0 } );
}

sub strict_local_check {
    my ($self) = @_;

    return $self->_platform_check( { include_db => 0, strict => 1 } );
}

sub with_db_check {
    my ($self) = @_;

    return $self->_platform_check( { include_db => 1, strict => 0 } );
}

sub strict_with_db_check {
    my ($self) = @_;

    return $self->_platform_check( { include_db => 1, strict => 1 } );
}

sub _platform_check {
    my ( $self, $options ) = @_;

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

sub _os_preflight_check {
    my ($self) = @_;

    my $report = GPForum::Service::Operations::OSPreflight->new(
        runtime => $self->_runtime )->check;

    return {
        name   => 'os_preflight',
        status => $report->{status},
        report => $report,
    };
}

sub _profile_check {
    my ($self) = @_;

    my $result =
      GPForum::Service::Operations::Profile->new->evaluate( $self->_config );

    return {
        name   => 'operational_profile',
        report => $result,
        status => $result->{ok} ? 'ok' : 'fail',
    };
}

sub _query_budget_drift_check {
    my ($self) = @_;

    my $report =
      GPForum::Service::Operations::QueryBudget->new( schema => $self->_schema )
      ->drift_report;

    return {
        name   => 'query_budget_drift',
        status => $report->{status},
        report => $report,
    };
}

sub _config {
    my ($self) = @_;

    if ( $self->config ) {
        return $self->config;
    }

    return GPForum::Config->from_environment;
}

sub _runtime {
    my ($self) = @_;

    if ( $self->runtime ) {
        return $self->runtime;
    }

    return GPForum::Runtime->from_config( $self->_config );
}

sub _schema {
    my ($self) = @_;

    if ( $self->schema ) {
        return $self->schema;
    }

    require GPForum::Schema;
    return GPForum::Schema->connect_from_config( $self->_config );
}

sub _exit_status {
    my ( $checks, $strict ) = @_;

    return 1 if any { $_->{status} eq 'fail' } @{$checks};
    return 0 if !$strict;

    return ( any { $_->{status} ne 'ok' } @{$checks} ) ? 1 : 0;
}

sub _command {
    my (@arguments) = @_;

    my $command = shift @arguments;
    return defined $command ? $command : '--local';
}

sub _method_for {
    my ($command) = @_;

    return 'local_check'          if $command eq '--local';
    return 'strict_local_check'   if $command eq '--strict-local';
    return 'with_db_check'        if $command eq '--with-db';
    return 'strict_with_db_check' if $command eq '--strict-with-db';

    return;
}

sub _usage {
    return
"Usage: bin/gpforum-platform-check --local|--strict-local|--with-db|--strict-with-db\n";
}

1;
