package GPForum::Command::ScheduledJobs;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT => 100;

has app    => undef;
has jobs   => undef;
has output => sub { return \*STDOUT; };

sub run {
    my ( $self, @arguments ) = @_;

    my $options = _parse_arguments(@arguments);
    return _print_usage( $self->output ) if $options->{help};

    my $summary = $self->run_once($options);
    _print_summary( $self->output, $summary );

    return 0;
}

sub run_once {
    my ( $self, $options ) = @_;

    return $self->_runner->run(
        {
            jobs  => $options->{jobs},
            limit => $options->{limit},
        }
    );
}

sub _runner {
    my ($self) = @_;

    return $self->jobs if $self->jobs;

    require GPForum;
    my $application = $self->app || GPForum->new;
    return $application->build_controller->gp_scheduled_jobs;
}

sub _parse_arguments {
    my (@arguments) = @_;

    my %options = (
        jobs  => [],
        limit => $DEFAULT_LIMIT,
    );

    while (@arguments) {
        my $argument = shift @arguments;
        _apply_argument( \%options, $argument, \@arguments );
    }

    return \%options;
}

sub _apply_argument {
    my ( $options, $argument, $arguments ) = @_;

    if ( $argument eq '--help' ) {
        $options->{help} = 1;
        return;
    }
    if ( $argument eq '--once' ) {
        return;
    }
    if ( $argument eq '--limit' ) {
        $options->{limit} = _positive_integer( $argument, shift @{$arguments} );
        return;
    }
    if ( $argument eq '--job' ) {
        push @{ $options->{jobs} }, _job_name( shift @{$arguments} );
        return;
    }

    croak _usage("unknown option $argument");
}

sub _job_name {
    my ($value) = @_;

    croak _usage('--job requires a job name') if !defined $value;
    croak _usage("unknown job $value")        if !_known_job($value);

    return $value;
}

sub _known_job {
    my ($value) = @_;

    require GPForum::Service::Operations::ScheduledJobs;
    for my $name (
        @{ GPForum::Service::Operations::ScheduledJobs->new->job_names } )
    {
        return 1 if $name eq $value;
    }

    return 0;
}

sub _positive_integer {
    my ( $option, $value ) = @_;

    croak _usage("$option requires a positive integer")
      if !defined $value || $value !~ /\A [[:digit:]]+ \z/msx || $value < 1;

    return int $value;
}

sub _print_summary {
    my ( $output, $summary ) = @_;

    print {$output} join( q{ },
        'scheduled_jobs',
        map { _summary_pair( $_, $summary ) } @{ _summary_keys($summary) } ),
      "\n"
      or croak 'failed to write scheduled jobs summary';

    return;
}

sub _summary_keys {
    my ($summary) = @_;

    return [ 'ok', grep { $_ ne 'ok' } sort keys %{$summary} ];
}

sub _summary_pair {
    my ( $name, $summary ) = @_;

    my $value = $summary->{$name};
    if ( ref $value eq 'HASH' ) {
        return join q{=}, $name, _job_count($value);
    }

    return join q{=}, $name, defined $value ? $value : 0;
}

sub _job_count {
    my ($result) = @_;

    if ( exists $result->{deleted} ) {
        return $result->{deleted};
    }
    if ( exists $result->{plans} ) {
        return scalar @{ $result->{plans} };
    }

    return $result->{ok} ? 1 : 0;
}

sub _print_usage {
    my ($output) = @_;

    print {$output} _usage() or croak 'failed to write scheduled jobs usage';

    return 0;
}

sub _usage {
    my ($message) = @_;

    return ( defined $message ? "$message\n" : q{} )
      . "Usage: bin/gpforum-scheduled-jobs [--once] [--limit N] [--job NAME]\n";
}

1;

__END__

=head1 NAME

GPForum::Command::ScheduledJobs - Timer entrypoint for operational jobs.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::Command::ScheduledJobs->new->run(@ARGV);

=head1 DESCRIPTION

Oneshoots the scheduled operational runner. systemd timers and launchd
intervals invoke this command; it is not a long-running daemon.

=head1 SUBROUTINES/METHODS

=head2 run

Parses CLI options, runs one batch, and prints a summary.

=head2 run_once

Runs the selected jobs with the parsed options.

=head1 DIAGNOSTICS

Throws for unknown options or job names.

=head1 CONFIGURATION AND ENVIRONMENT

Reads C<GPFORUM_*> settings through L<GPForum::Config> when the application
is constructed.

=head1 DEPENDENCIES

Uses L<Carp>, L<Const::Fast>, and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

C<--once> is accepted for symmetry with the outbox command and is the only
supported mode.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
