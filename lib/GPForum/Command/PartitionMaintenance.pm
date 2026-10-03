# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::PartitionMaintenance;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

use GPForum::Command::Usage;

our $VERSION = '0.001';

const my $EXIT_FAILURE => 1;
const my $EXIT_USAGE   => 2;
const my @COUNT_KEYS   => qw(created existing planned conflicts errors);

# What --json keeps of a partition row: the fields the lines print, under the
# lifecycle's own names, and nothing it may add for its own use later.
const my @ROW_KEYS => qw(conflicting_rows create_sql default_partition error
  message partition_name range_end range_start remediation table_name);

has dbh       => undef;
has lifecycle => undef;
has output    => sub { return \*STDOUT; };

sub run ( $self, @arguments ) {
    my $options = eval { return _parse_arguments(@arguments) };
    if ( !$options ) {
        return _print_error( _trim($EVAL_ERROR) );
    }
    return _print_usage( $self->output ) if $options->{help};

    # The lines got the reason with croak's "at FILE line N" still on, and
    # unredacted, where --json had both handled: one path for both now.
    my $result = eval { return $self->ensure($options) };
    if ( !$result ) {
        return GPForum::Command::Usage->failure(
            $EVAL_ERROR,
            $options->{json}
            ? (
                $self->output,
                {
                    %{ _json_head($options) },
                    lookahead_months => $options->{lookahead},
                }
              )
            : ()
        );
    }
    if ( $options->{json} ) {
        GPForum::Command::Usage->json( $self->output,
            _json_document( $result, $options ) );
    }
    else {
        $self->_print_result( $result, $options );
    }

    return $result->{ok} ? 0 : $EXIT_FAILURE;
}

sub ensure ( $self, $options ) {
    return $self->_lifecycle->ensure_partitions(
        {
            apply            => $options->{apply},
            dbh              => $self->dbh,
            lookahead_months => $options->{lookahead},
        }
    );
}

sub _lifecycle ($self) {
    return $self->lifecycle if $self->lifecycle;

    require GPForum::Config;
    require GPForum::Schema;
    require GPForum::Service::Operations::PartitionLifecycle;
    my $schema =
      GPForum::Schema->connect_from_config( GPForum::Config->from_environment );

    return GPForum::Service::Operations::PartitionLifecycle->new(
        schema => $schema );
}

# The lines' content as one object: the summary's counts become the lists
# themselves, so a script reads how many from their length.
sub _json_document ( $result, $options ) {
    return {
        %{ _json_head($options) },
        %{ __PACKAGE__->result_document($result) },
    };
}

# Public so bin/gpforum-migrate, which ensures the window after migrating,
# reports it in the same shape as this command's --json.
sub result_document ( $class, $result ) {
    return {
        lookahead_months => $result->{lookahead_months},
        skipped          => $result->{skipped} ? 1    : 0,
        status           => $result->{ok}      ? 'ok' : 'fail',
        map {
            $_ => [ map { _json_row($_) } @{ $result->{$_} || [] } ]
        } @COUNT_KEYS,
    };
}

sub _json_head ($options) {
    return {
        command => 'gpforum-partition-maintenance',
        mode    => $options->{apply} ? 'apply' : 'plan',
        map { $_ => [] } @COUNT_KEYS,
    };
}

sub _json_row ($row) {
    return { map { $_ => $row->{$_} } grep { defined $row->{$_} } @ROW_KEYS };
}

sub _print_result ( $self, $result, $options ) {
    my $output = $self->output;
    _print_line( $output, _summary_line( $result, $options ) );
    for my $key (@COUNT_KEYS) {
        _print_rows( $output, $key, $result->{$key} );
    }

    return;
}

sub _summary_line ( $result, $options ) {
    return join q{ }, 'partition_maintenance',
      'mode=' . ( $options->{apply} ? 'apply' : 'plan' ),
      'ok=' .   ( $result->{ok}     ? 1       : 0 ),
      'lookahead=' . $result->{lookahead_months},
      ( map { $_ . q{=} . scalar @{ $result->{$_} || [] } } @COUNT_KEYS ),
      'skipped=' . ( $result->{skipped} ? 1 : 0 );
}

sub _print_rows ( $output, $key, $rows ) {
    for my $row ( @{ $rows || [] } ) {
        _print_line( $output, _row_line( $key, $row ) );
        _print_remediation( $output, $row->{remediation} );
    }

    return;
}

sub _row_line ( $key, $row ) {
    my @fields = (
        $key,
        $row->{partition_name},
        'range=' . $row->{range_start} . q{..} . $row->{range_end},
    );
    if ( defined $row->{conflicting_rows} ) {
        push @fields, 'default=' . $row->{default_partition},
          'rows=' . $row->{conflicting_rows}, 'message=' . $row->{message};
    }
    if ( defined $row->{error} && $key eq 'errors' ) {
        push @fields, 'error=' . $row->{error};
    }
    if ( defined $row->{create_sql} ) {
        push @fields, 'sql=' . $row->{create_sql};
    }

    return join q{ }, @fields;
}

sub _print_remediation ( $output, $steps ) {
    for my $step ( @{ $steps || [] } ) {
        _print_line( $output, 'remediation ' . $step );
    }

    return;
}

sub _print_line ( $output, $line ) {
    print {$output} $line, "\n"
      or croak 'failed to write partition maintenance output';

    return;
}

sub _parse_arguments (@arguments) {
    my %options = (
        apply => 0,
        help  => 0,
        json  => 0,
    );
    while (@arguments) {
        my $argument = shift @arguments;
        _apply_argument( \%options, $argument, \@arguments );
    }

    return \%options;
}

sub _apply_argument ( $options, $argument, $arguments ) {
    my %flag = (
        '--apply' => sub { $options->{apply} = 1 },
        '--help'  => sub { $options->{help}  = 1 },
        '--json'  => sub { $options->{json}  = 1 },
        '--plan'  => sub { $options->{apply} = 0 },
    );
    if ( $flag{$argument} ) {
        $flag{$argument}->();
        return;
    }
    if ( $argument eq '--lookahead' ) {
        $options->{lookahead} = _positive_integer( shift @{$arguments} );
        return;
    }

    croak _usage("unknown option $argument");
}

sub _positive_integer ($value) {
    croak _usage('--lookahead requires a positive integer')
      if !defined $value
      || $value !~ /\A [[:digit:]]+ \z/msx
      || $value < 1;

    return int $value;
}

sub _print_error ( $message, $status = undef ) {
    print {*STDERR} $message, "\n"
      or croak 'failed to write partition maintenance error';

    return defined $status ? $status : $EXIT_USAGE;
}

sub _print_usage ($output) {
    print {$output} _usage()
      or croak 'failed to write partition maintenance usage';

    return 0;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _usage ( $message = undef ) {
    return ( defined $message ? "$message\n" : q{} ) . <<'USAGE';
Usage: bin/gpforum-partition-maintenance [--plan|--apply] [--lookahead N] [--json]

Creates the monthly range partitions of event_log, audit_log and
notifications ahead of time and records them in partition_registry.

  --plan       report the DDL without executing it (default)
  --apply      create each missing month and ATTACH it, and upsert the registry
  --lookahead  months to keep ahead, including the current month (default 3)
  --json       one JSON object on stdout instead of lines
  --help       show this help

A run that finds another holding the maintenance lock does nothing and
says skipped=1. Exit status is 1 when a partition cannot be created,
including when rows in the DEFAULT partition overlap the new range. The
printed remediation steps take ACCESS EXCLUSIVE locks and belong in a
maintenance window.
USAGE
}

sub _trim ($error) {
    my $text = "$error";
    $text =~ s/\s+\z//msx;

    return $text;
}

1;

__END__

=head1 NAME

GPForum::Command::PartitionMaintenance - Monthly partition maintenance CLI.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::Command::PartitionMaintenance->new->run(@ARGV);

=head1 DESCRIPTION

Oneshot maintenance entrypoint for
L<GPForum::Service::Operations::PartitionLifecycle>. The daily
F<deploy/systemd/gpforum-partition-maintenance.timer>, its launchd and
FreeBSD counterparts, and C<bin/gpforum-migrate --apply> at every deploy
invoke C<bin/gpforum-partition-maintenance --apply> or its lifecycle, so the
lookahead window never runs out (ADR 0113). It is not a long-running daemon.

C<--plan> prints the C<CREATE TABLE ... (LIKE ...)> and C<ATTACH PARTITION>
statements without executing anything, so the DDL can be reviewed or applied
by hand.

=head1 SUBROUTINES/METHODS

=head2 run

Parses CLI options, runs one maintenance pass, prints the result -- as lines,
or with C<--json> as one JSON object -- and returns the exit status: 0 when
every partition is in place, or when another run holds the maintenance lock
and this one is skipped, 1 when a partition is missing because of a conflict
or error, 2 for usage errors.

=head2 ensure

Runs one pass through L<GPForum::Service::Operations::PartitionLifecycle>.

=head2 result_document

Takes a lifecycle result and returns what C<--json> prints of it, less
C<command> and C<mode>: C<status>, C<skipped>, C<lookahead_months> and the
lists C<created>, C<existing>, C<planned>, C<conflicts> and C<errors>, each
row cut down to the fields the lines print. L<GPForum::Command::Migrate>
reports its partition step with it.

=head1 DIAGNOSTICS

Usage errors and lifecycle exceptions are printed to STDERR. Default-partition
overlaps are printed as C<conflicts> rows with their remediation statements.

=head1 CONFIGURATION AND ENVIRONMENT

Reads C<GPFORUM_*> database settings through L<GPForum::Config> unless a
lifecycle or handle is injected.

=head1 DEPENDENCIES

Uses L<Carp>, L<Const::Fast>, L<English>, and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Detach, archive, and drop remain operator-owned, and so does clearing a
default-partition overlap.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
