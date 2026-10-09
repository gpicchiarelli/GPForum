# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::ReadinessFindings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Findings;

our $VERSION = '0.001';

# The readiness report (GPForum::Service::Operations::Readiness, the body of
# /health/ready) as an operator reads it: one line per check, named as an
# operator names the thing checked, and under a check that is not ok what
# to type, else the runbook the report names. `gpforum status` reads the
# report from the running service; `gpforum doctor` makes one itself. Both
# read it through this, so the two never word one check two ways.

# What each check is called, by the name the report gives it.
const my %LABEL => (
    antivirus            => 'status.label_antivirus',
    database             => 'status.label_database',
    endpointquerybudget  => 'status.label_budget_table',
    eventlog             => 'status.label_event_table',
    operational_profile  => 'status.label_profile',
    os_preflight         => 'status.label_host',
    outboxmessage        => 'status.label_outbox_table',
    partition_horizon    => 'status.label_partitions',
    projectiongeneration => 'status.label_projection_table',
    query_budget_drift   => 'status.label_budgets',
    replication_slots    => 'status.label_replication',
    runtime              => 'status.label_runtime',
    runtime_enforcement  => 'status.label_processes',
    shared_cache         => 'status.label_cache',
);

# What fixes a check that is not ok, when one command does: the tables the
# migrations create, the budgets and the partitions. The rest point at their
# runbook.
const my $MIGRATE => 'gpforum migrate';
const my %FIX => (
    antivirus            => 'gpforum antivirus-check',
    database             => 'gpforum doctor',
    endpointquerybudget  => $MIGRATE,
    eventlog             => $MIGRATE,
    outboxmessage        => $MIGRATE,
    partition_horizon    => 'gpforum partitions --apply',
    projectiongeneration => $MIGRATE,
    query_budget_drift   => 'gpforum budgets --sync',
);

# The commands above that say why rather than repair: "gpforum
# antivirus-check says why".
const my %EXPLAINS => map { $_ => 1 } qw(antivirus database);

# The modes a check reports, by check and mode, in the operator's words.
const my %MODE => (
    'antivirus/format-check'      => 'status.mode_format_check',
    'shared_cache/disabled'       => 'status.mode_cache_disabled',
    'shared_cache/local-fallback' => 'status.mode_cache_fallback',
    'shared_cache/shared'         => 'status.mode_cache_shared',
);

const my $MAX_REASON_ITEMS => 3;
const my $SERVICE_USER     => 'gpforum';

has catalog => sub { return GPForum::Service::I18N::CliCatalog->new; };

# What goes before a command an operator types, such as "sudo -u gpforum ",
# so the command runs as the service does.
has command_prefix => q{};

# Takes a readiness report and, optionally, skip (the names of checks to
# leave out, which the caller reports itself), collapse (true to write the
# checks that pass as one line) and findings (a list to add to). Returns the
# findings.
sub findings ( $self, $report, %options ) {
    my $findings = $options{findings}
      // GPForum::Service::Operations::Findings->new(
        catalog => $self->catalog );
    my %skip = map { $_ => 1 } @{ $options{skip} // [] };
    my @checks =
      grep { !$skip{ $_->{name} // q{} } } @{ $report->{checks} // [] };

    my @passing = grep { ( $_->{status} // q{} ) eq 'ok' } @checks;
    if ( $options{collapse} ) {
        if (@passing) {
            $findings->add(
                name    => 'readiness',
                status  => 'ok',
                message => [
                    'status.passing',
                    { count => scalar @passing, path => '/health/ready' }
                ],
            );
        }
    }
    else {
        for my $check (@passing) {
            $findings->add( $self->_passed($check) );
        }
    }
    for my $check ( grep { ( $_->{status} // q{} ) ne 'ok' } @checks ) {
        $findings->add( $self->_problem($check) );
    }

    return $findings;
}

# Deployed, a command an operator types for the forum runs as the service's
# user -- sudo -u gpforum -- so it reads what the service reads, with the
# service's permissions. Not in development, not for launchd, whose
# services run as root, and not for the service's user itself.
sub service_user_prefix ( $class, $host ) {
    return q{} if !$host->is_deployed;
    return q{} if ( $host->service_manager // q{} ) eq 'launchd';

    my $user = getpwuid $EFFECTIVE_USER_ID;
    return q{} if ( $user // q{} ) eq $SERVICE_USER;

    return "sudo -u $SERVICE_USER ";
}

# The line an operator reads for a check, as a name: "database", "query
# budgets".
sub label ( $self, $name ) {
    return $self->catalog->text( $LABEL{$name} ) if exists $LABEL{$name};

    return $name =~ tr/_/ /r;
}

sub _passed ( $self, $check ) {
    my $detail = $self->_mode_detail($check);

    return (
        name    => $check->{name},
        status  => 'ok',
        message => defined $detail
        ? [
            'status.check_detail',
            { label => $self->label( $check->{name} ), detail => $detail }
          ]
        : $self->label( $check->{name} ),
    );
}

sub _problem ( $self, $check ) {
    my $status = $check->{status} // 'fail';
    my $reason = $self->_reason($check);

    return (
        name    => $check->{name},
        status  => $status eq 'degraded' ? 'degraded' : 'fail',
        message => [
            length $reason ? 'status.check_detail' : 'status.check_failed',
            {
                label  => $self->label( $check->{name} ),
                detail => $reason,
            }
        ],
        fixes => $self->_fixes($check),
    );
}

sub _fixes ( $self, $check ) {
    my $name = $check->{name} // q{};
    my @fixes;
    if ( exists $FIX{$name} ) {
        my $command = $self->command_prefix . $FIX{$name};
        push @fixes,
          exists $EXPLAINS{$name}
          ? [ 'status.fix_says_why', { command => $command } ]
          : $command;
    }
    if ( defined $check->{runbook} && !@fixes ) {
        push @fixes, [ 'status.fix_runbook', { runbook => $check->{runbook} } ];
    }

    return \@fixes;
}

# A mode worth an operator's reading -- the shared cache's, the antivirus's
# -- in the operator's words where the catalogs have them, not the "no
# catalog" a test double leaves. The report's own note is in the service's
# language, which need not be the operator's.
sub _mode_detail ( $self, $check ) {
    my $mode = $check->{mode};
    return undef if !defined $mode || $mode eq 'no catalog';

    my $known = ( $check->{name} // q{} ) . q{/} . $mode;
    return exists $MODE{$known} ? $self->catalog->text( $MODE{$known} ) : $mode;
}

# Why a check is not ok, in the report's own words: its error, its mode, or
# the parts of its report that are not ok.
sub _reason ( $self, $check ) {
    return _shortened( $check->{error} ) if defined $check->{error};

    my $report = $check->{report};
    if ( ref $report eq 'HASH' ) {
        my $from_report = _report_reason($report);
        return $from_report if length $from_report;
    }
    if ( ref $check->{checks} eq 'ARRAY' ) {
        my @names = map { $_->{name} }
          grep { ( $_->{status} // q{} ) ne 'ok' } @{ $check->{checks} };
        return _listed(@names) if @names;
    }

    return $self->_mode_detail($check) // q{};
}

sub _report_reason ($report) {
    if ( ref $report->{errors} eq 'HASH' ) {
        return _listed(
            map { "$_: $report->{errors}{$_}" }
            sort keys %{ $report->{errors} }
        );
    }
    my @drifted = map { @{ $report->{$_} // [] } } qw(missing extra mismatched);
    if (@drifted) {
        return _listed( map { ref $_ ? $_->{endpoint_name} // q{} : $_ }
              @drifted );
    }
    if ( ref $report->{tables} eq 'ARRAY' ) {
        return _listed(
            map  { $_->{table} }
            grep { ( $_->{status} // 'ok' ) ne 'ok' } @{ $report->{tables} }
        );
    }
    if ( defined $report->{error} ) {
        return _shortened( $report->{error} );
    }

    return q{};
}

# At most a few names, then how many more: a reason is one line.
sub _listed (@names) {
    @names = grep { defined && length } @names;
    return q{} if !@names;
    return join q{, }, @names if @names <= $MAX_REASON_ITEMS;

    return
      join( q{, }, @names[ 0 .. $MAX_REASON_ITEMS - 1 ] ) . ', +'
      . ( @names - $MAX_REASON_ITEMS );
}

# DBI's errors repeat themselves over several lines; the first says it.
sub _shortened ($text) {
    my ($first) = split /\n/msx, "$text";
    $first //= q{};
    $first =~ s/\s+\z//msx;

    return $first;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::ReadinessFindings - The readiness report as an
operator reads it.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $findings = GPForum::Service::Operations::ReadinessFindings->new(
        command_prefix => 'sudo -u gpforum ' )->findings($report);
    print $findings->human_text;

=head1 DESCRIPTION

Turns the report C</health/ready> answers with
(L<GPForum::Service::Operations::Readiness/check>) into
L<GPForum::Service::Operations::Findings>: a check mark for a check that
passes, C<!> for a degraded one and a cross for a failed one, each named as
an operator names the thing checked, and under a problem the command that
fixes it -- C<gpforum migrate> for a missing table, C<gpforum budgets
--sync>, C<gpforum partitions --apply> -- or the runbook the report names.
C<gpforum status> and C<gpforum doctor> both write the report through it.

=head1 SUBROUTINES/METHODS

=head2 catalog

The L<GPForum::Service::I18N::CliCatalog> the words come from.

=head2 command_prefix

What goes before each command a fix names, such as C<sudo -u gpforum >;
empty by default.

=head2 findings

Takes the report and the options C<skip> (check names to leave out),
C<collapse> (write the passing checks as one line) and C<findings> (a list
to add to). Returns the findings.

=head2 service_user_prefix

Class method. Takes a L<GPForum::Service::Operations::Host> and returns
C<sudo -u gpforum > when commands on that host should run as the service's
user, else the empty string.

=head2 label

The name an operator reads for a check, in the catalog's language; a name
it does not know, with spaces for underscores.

=head1 DIAGNOSTICS

None: a check it does not know is written under its own name.

=head1 CONFIGURATION AND ENVIRONMENT

The language follows C<LC_ALL>, C<LC_MESSAGES> or C<LANG> unless a catalog
is given.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>,
L<GPForum::Service::I18N::CliCatalog>,
L<GPForum::Service::Operations::Findings>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A reason is read from the report's C<error>, C<errors>, drift lists,
tables or sub-checks; a check whose report has another shape is named
without one.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
