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
        my $result = $budget->sync_schema;
        return {
            %document,
            mode    => 'sync',
            removed => $result->{removed},
            status  => 'ok',
            synced  => $result->{synced},
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
    my @removed = @{ $result->{removed} };
    if (@removed) {
        print 'removed '
          . scalar(@removed)
          . ' dropped endpoint query budgets: '
          . join( q{,}, @removed ) . "\n"
          or croak 'failed to write query budget sync result';
    }

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

Reads the endpoint query budget catalog in the code and compares it with
the copy in the endpoint_query_budgets table.

  --print  print the catalog (the default)
  --sync   make the table match the catalog: insert missing rows, update
           rows that differ, delete rows for endpoints the catalog dropped
  --check  fail while the table and the catalog differ, naming each
           missing, extra or mismatched endpoint
  --json   one JSON object on stdout instead of lines
  --help   show this help

Exit status: 0 success, 1 drift or a failure, 2 usage error.
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

__END__

=head1 NAME

GPForum::Command::QueryBudget - Prints, syncs and checks the endpoint query budget table.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::Command::QueryBudget->new->run(@ARGV);

=head1 DESCRIPTION

The CLI behind C<bin/gpforum-query-budget> and C<script/query-budget>, over
L<GPForum::Service::Operations::QueryBudget>. C<--print> shows the catalog
in the code. C<--sync> makes the C<endpoint_query_budgets> table match it:
missing rows are inserted, rows with other limits or notes updated, and rows
for endpoints the catalog no longer has deleted, so C<--check> passes after
it. C<--check> exits 1 while the table differs, naming the missing, extra and
mismatched endpoints. C<--json> answers with one object; C<--sync --json>
carries C<synced> (the catalog size) and C<removed> (the endpoints whose rows
were deleted).

=head1 SUBROUTINES/METHODS

=head2 run

Parses the arguments, runs one mode and returns the exit status.

=head2 print_catalog

Prints one line per catalog endpoint. Returns 0.

=head2 sync_catalog

Makes the table match the catalog, prints the number of endpoints and, when
it deleted any, the dropped endpoints it removed. Returns 0.

=head2 check_catalog

Prints C<ok> or the drift line. Returns 0 without drift, 1 with it.

=head2 usage_text

The text C<--help> prints, for the command adapter in
L<GPForum::CLI::query_budget>.

=head1 DIAGNOSTICS

Misuse exits 2 with the usage on standard error. Drift exits 1. A database
error exits 1 with its reason on standard error and, with C<--json>, a
document with C<status> C<fail> on standard output.

=head1 CONFIGURATION AND ENVIRONMENT

Without a C<schema> attribute it connects with the C<GPFORUM_DATABASE_*>
settings read by L<GPForum::Config>.

=head1 DEPENDENCIES

L<GPForum::Service::Operations::QueryBudget>, L<GPForum::Schema>,
L<GPForum::Config> and L<GPForum::Command::Usage>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

C<--sync> deletes the row of any endpoint the catalog does not name: run it
with the release whose catalog is meant to be the source of truth, not with
an older checkout against a newer database.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
