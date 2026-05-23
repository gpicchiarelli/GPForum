package GPForum::Command::QueryBudget;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

use GPForum::Config;
use GPForum::Schema;
use GPForum::Service::Operations::QueryBudget;

our $VERSION = '0.001';

has schema => undef;

sub run {
    my ( $self, @arguments ) = @_;

    my $command = _command(@arguments);
    my $method  = _method_for($command);

    croak _usage() if !defined $method;

    return $self->$method();
}

sub print_catalog {
    my ($self) = @_;

    my $catalog = GPForum::Service::Operations::QueryBudget->new->catalog;
    for my $endpoint_name ( sort keys %{$catalog} ) {
        my $budget = $catalog->{$endpoint_name};
        print
"$endpoint_name queries=$budget->{max_queries} transactions=$budget->{max_transactions} $budget->{notes}\n"
          or croak 'failed to write query budget catalog';
    }

    return 0;
}

sub sync_catalog {
    my ($self) = @_;

    my $budget = GPForum::Service::Operations::QueryBudget->new(
        schema => $self->_schema );
    my $result = $budget->sync_schema;

    print "synced $result->{synced} endpoint query budgets\n"
      or croak 'failed to write query budget sync result';

    return 0;
}

sub check_catalog {
    my ($self) = @_;

    my $budget = GPForum::Service::Operations::QueryBudget->new(
        schema => $self->_schema );
    my $report = $budget->drift_report;

    if ( $report->{status} eq 'ok' ) {
        print "ok endpoint query budgets aligned\n"
          or croak 'failed to write query budget check result';
        return 0;
    }

    print _drift_line($report)
      or croak 'failed to write query budget drift result';

    return 1;
}

sub _schema {
    my ($self) = @_;

    return $self->schema if $self->schema;

    my $config = GPForum::Config->from_environment;
    return GPForum::Schema->connect_from_config($config);
}

sub _command {
    my (@arguments) = @_;

    my $command = shift @arguments;
    return defined $command ? $command : '--print';
}

sub _method_for {
    my ($command) = @_;

    return 'print_catalog' if $command eq '--print';
    return 'sync_catalog'  if $command eq '--sync';
    return 'check_catalog' if $command eq '--check';

    return;
}

sub _usage {
    return "Usage: bin/gpforum-query-budget --print|--sync|--check\n";
}

sub _drift_line {
    my ($report) = @_;

    return join q{ },
      'fail endpoint query budget drift',
      'missing=' . join( q{,}, @{ $report->{missing} } ),
      'extra=' . join( q{,}, @{ $report->{extra} } ),
      'mismatched=' . join( q{,}, @{ $report->{mismatched} } ),
      "\n";
}

1;
