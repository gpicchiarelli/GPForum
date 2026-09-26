# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::PartitionMaintenance;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $EXIT_FAILURE => 1;
const my $EXIT_USAGE   => 2;
const my @COUNT_KEYS   => qw(created existing planned conflicts errors);

has dbh       => undef;
has lifecycle => undef;
has output    => sub { return \*STDOUT; };

sub run ( $self, @arguments ) {
    my $options = eval { return _parse_arguments(@arguments) };
    if ( !$options ) {
        return _print_error( _trim($EVAL_ERROR) );
    }
    return _print_usage( $self->output ) if $options->{help};

    my $result = eval { return $self->ensure($options) };
    if ( !$result ) {
        return _print_error( _trim($EVAL_ERROR), $EXIT_FAILURE );
    }
    $self->_print_result( $result, $options );

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
      map { $_ . q{=} . scalar @{ $result->{$_} || [] } } @COUNT_KEYS;
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
Usage: bin/gpforum-partition-maintenance [--plan|--apply] [--lookahead N]

Creates the monthly range partitions of event_log, audit_log and
notifications ahead of time and records them in partition_registry.

  --plan       report the DDL without executing it (default)
  --apply      execute CREATE TABLE ... PARTITION OF and upsert the registry
  --lookahead  months to keep ahead, including the current month (default 3)
  --help       show this help

Exit status is 1 when a partition cannot be created, including when rows in
the DEFAULT partition overlap the new range. The printed remediation steps
take ACCESS EXCLUSIVE locks and belong in a maintenance window.
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
L<GPForum::Service::Operations::PartitionLifecycle>. A systemd timer, launchd
interval, or operator crontab invokes C<bin/gpforum-partition-maintenance
--apply> often enough that the lookahead window never runs out; it is not a
long-running daemon and it ships no scheduler unit of its own.

C<--plan> prints the C<CREATE TABLE ... PARTITION OF> statements without
executing anything, so the DDL can be reviewed or applied by hand.

=head1 SUBROUTINES/METHODS

=head2 run

Parses CLI options, runs one maintenance pass, prints the result, and returns
the exit status: 0 when every partition is in place, 1 when a partition is
missing because of a conflict or error, 2 for usage errors.

=head2 ensure

Runs one pass through L<GPForum::Service::Operations::PartitionLifecycle>.

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
