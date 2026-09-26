# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::ScheduledJobs;

use strict;
use warnings;

use Carp    qw(croak);
use English qw(-no_match_vars);
use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Command::Usage;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT => 100;

# The application, or a code reference that builds it -- built only when work
# actually runs, so --help needs no configuration. The entry point, which is
# the composition layer, supplies it: a command does not reach up to the
# application class for it (ADR 0107).
has app    => undef;
has jobs   => undef;
has output => sub { return \*STDOUT; };

# A usage croak becomes the documented usage exit instead of an uncaught
# exception: same text, on stderr, status 2, without croak's " at FILE line N".
# Anything else is rethrown, so a real failure is not relabelled as misuse.
sub run ( $self, @arguments ) {
    my $status = eval { return $self->_run(@arguments); };
    return $status if defined $status;

    my $error = GPForum::Command::Usage->trimmed($EVAL_ERROR);
    if ( !GPForum::Command::Usage->is_usage($error) ) {
        die "$error\n";
    }

    return GPForum::Command::Usage->error( undef, $error );
}

sub _run ( $self, @arguments ) {
    my $options = _parse_arguments(@arguments);
    return _print_usage( $self->output ) if $options->{help};

    my $summary = $self->run_once($options);
    _print_summary( $self->output, $summary );

    # Non-zero when a job failed, so the timer unit is marked failed and can
    # alert rather than recording a clean run.
    return $summary->{ok} ? 0 : 1;
}

sub run_once ( $self, $options ) {
    return $self->_runner->run(
        {
            jobs  => $options->{jobs},
            limit => $options->{limit},
        }
    );
}

sub _runner ($self) {
    return $self->jobs if $self->jobs;

    return $self->_application->build_controller->gp_scheduled_jobs;
}

sub _application ($self) {
    my $app = $self->app
      or croak 'this command was built without an application';

    return ref $app eq 'CODE' ? $app->() : $app;
}

sub _parse_arguments (@arguments) {
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

sub _apply_argument ( $options, $argument, $arguments ) {
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

sub _job_name ($value) {
    croak _usage('--job requires a job name') if !defined $value;
    croak _usage("unknown job $value")        if !_known_job($value);

    return $value;
}

sub _known_job ($value) {
    require GPForum::Service::Operations::ScheduledJobs;
    for my $name (
        @{ GPForum::Service::Operations::ScheduledJobs->new->job_names } )
    {
        return 1 if $name eq $value;
    }

    return 0;
}

sub _positive_integer ( $option, $value ) {
    croak _usage("$option requires a positive integer")
      if !defined $value || $value !~ /\A [[:digit:]]+ \z/msx || $value < 1;

    return int $value;
}

sub _print_summary ( $output, $summary ) {
    print {$output} join( q{ },
        'scheduled_jobs',
        map { _summary_pair( $_, $summary ) } @{ _summary_keys($summary) } ),
      "\n"
      or croak 'failed to write scheduled jobs summary';

    return;
}

sub _summary_keys ($summary) {
    return [ 'ok', grep { $_ ne 'ok' } sort keys %{$summary} ];
}

sub _summary_pair ( $name, $summary ) {
    my $value = $summary->{$name};
    if ( ref $value eq 'HASH' ) {
        return join q{ }, join( q{=}, $name, _job_count($value) ),
          _job_notes( $name, $value );
    }

    return join q{=}, $name, defined $value ? $value : 0;
}

# What a count alone hides: why a job did nothing, and what went wrong.
sub _job_notes ( $name, $result ) {
    my @notes;
    if ( defined $result->{skipped} ) {
        push @notes, qq{${name}_skipped="$result->{skipped}"};
    }
    if ( defined $result->{error} ) {
        push @notes, qq{${name}_error="$result->{error}"};
    }
    if ( ref $result->{errors} eq 'ARRAY' ) {
        push @notes, "${name}_errors=" . scalar @{ $result->{errors} };
    }

    return @notes;
}

sub _job_count ($result) {
    if ( exists $result->{deleted} ) {
        return $result->{deleted};
    }
    if ( exists $result->{plans} ) {
        return scalar @{ $result->{plans} };
    }
    if ( exists $result->{scanned} ) {
        return $result->{scanned};
    }

    return $result->{ok} ? 1 : 0;
}

sub _print_usage ($output) {
    print {$output} _usage() or croak 'failed to write scheduled jobs usage';

    return 0;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _usage ( $message = undef ) {
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

    exit GPForum::Command::ScheduledJobs->new( app => sub { GPForum->new } )
      ->run(@ARGV);

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
