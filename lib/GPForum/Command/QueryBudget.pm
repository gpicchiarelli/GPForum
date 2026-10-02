# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::QueryBudget;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Schema;
use GPForum::Service::Operations::QueryBudget;

our $VERSION = '0.001';

const my $COMMAND => 'gpforum-query-budget';
const my %METHOD_FOR => (
    '--check' => 'check_catalog',
    '--print' => 'print_catalog',
    '--sync'  => 'sync_catalog',
);

has schema => undef;

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->help( \*STDOUT, _usage() )
      if GPForum::Command::Usage->wants_help(@arguments);

    my $options = _options(@arguments);
    return GPForum::Command::Usage->error( $options->{error}, _usage() )
      if defined $options->{error};

    my $method = $METHOD_FOR{ $options->{mode} };
    if ( !$options->{json} ) {
        my $status = eval { return $self->$method() };
        return $status // GPForum::Command::Usage->failure($EVAL_ERROR);
    }

    my $document = eval { return $self->_json_document($method) };
    if ( !$document ) {
        return GPForum::Command::Usage->failure( $EVAL_ERROR, \*STDOUT,
            { command => $COMMAND, mode => substr $options->{mode}, 2 } );
    }
    GPForum::Command::Usage->json( \*STDOUT, $document );

    return $document->{status} eq 'ok'
      ? 0
      : $GPForum::Command::Usage::EXIT_FAILURE;
}

# The same three answers as one object each. --print's catalog is keyed by
# endpoint, as the service holds it; --check's lists are the endpoints the
# database is missing, has beyond the catalog, or holds with other numbers.
sub _json_document ( $self, $method ) {
    my %document = ( command => $COMMAND );
    if ( $method eq 'print_catalog' ) {
        return {
            %document,
            endpoints =>
              GPForum::Service::Operations::QueryBudget->new->catalog,
            mode   => 'print',
            status => 'ok',
        };
    }
    my $budget = GPForum::Service::Operations::QueryBudget->new(
        schema => $self->_schema );
    if ( $method eq 'sync_catalog' ) {
        return {
            %document,
            mode   => 'sync',
            status => 'ok',
            synced => $budget->sync_schema->{synced},
        };
    }
    my $report = $budget->drift_report;

    return {
        %document,
        mode => 'check',
        map { $_ => $report->{$_} } qw(extra missing mismatched status),
    };
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

# Every argument is read: `--print --bogus` used to print and exit 0, and a
# second mode was ignored rather than refused.
sub _options (@arguments) {
    my %options = ( json => 0 );
    for my $argument (@arguments) {
        if ( $argument eq '--json' ) {
            $options{json} = 1;
            next;
        }
        return { error => "unknown option $argument" }
          if !exists $METHOD_FOR{$argument};
        return { error => 'choose one of --print, --sync and --check' }
          if defined $options{mode} && $options{mode} ne $argument;
        $options{mode} = $argument;
    }
    $options{mode} //= '--print';

    return \%options;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return <<'USAGE';
Usage: bin/gpforum-query-budget [--print|--sync|--check] [--json]

Reads the query-plan budget catalog and compares it against the database.

  --print  print the catalog as it stands
  --sync   write the observed plans back into the catalog
  --check  fail if an observed plan is outside its budget
  --json   one JSON object on stdout instead of lines
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
