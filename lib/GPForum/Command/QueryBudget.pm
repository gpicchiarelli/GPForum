# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::QueryBudget;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base, -signatures;

use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Schema;
use GPForum::Service::Operations::QueryBudget;

our $VERSION = '0.001';

has schema => undef;

sub run ( $self, @arguments ) {
    my $command = _command(@arguments);

    return GPForum::Command::Usage->help( \*STDOUT, _usage() )
      if $command eq '--help' || $command eq '-h';

    my $method = _method_for($command);
    return GPForum::Command::Usage->error( "unknown option $command", _usage() )
      if !defined $method;

    return $self->$method();
}

sub print_catalog ($self) {
    my $catalog = GPForum::Service::Operations::QueryBudget->new->catalog;
    for my $endpoint_name ( sort keys %{$catalog} ) {
        my $budget = $catalog->{$endpoint_name};
        print
"$endpoint_name queries=$budget->{max_queries} transactions=$budget->{max_transactions} $budget->{notes}\n"
          or croak 'failed to write query budget catalog';
    }

    return 0;
}

sub sync_catalog ($self) {
    my $budget = GPForum::Service::Operations::QueryBudget->new(
        schema => $self->_schema );
    my $result = $budget->sync_schema;

    print "synced $result->{synced} endpoint query budgets\n"
      or croak 'failed to write query budget sync result';

    return 0;
}

sub check_catalog ($self) {
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

sub _schema ($self) {
    return $self->schema if $self->schema;

    my $config = GPForum::Config->from_environment;
    return GPForum::Schema->connect_from_config($config);
}

sub _command (@arguments) {
    my $command = shift @arguments;
    return defined $command ? $command : '--print';
}

sub _method_for ($command) {
    return 'print_catalog' if $command eq '--print';
    return 'sync_catalog'  if $command eq '--sync';
    return 'check_catalog' if $command eq '--check';

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
Usage: bin/gpforum-query-budget --print|--sync|--check

Reads the query-plan budget catalog and compares it against the database.

  --print  print the catalog as it stands
  --sync   write the observed plans back into the catalog
  --check  fail if an observed plan is outside its budget
  --help   show this help

Exit status: 0 success, 1 a budget was exceeded, 2 usage error.
USAGE
}

sub _drift_line ($report) {
    return join q{ },
      'fail endpoint query budget drift',
      'missing=' . join( q{,}, @{ $report->{missing} } ),
      'extra=' . join( q{,}, @{ $report->{extra} } ),
      'mismatched=' . join( q{,}, @{ $report->{mismatched} } ),
      "\n";
}

1;
