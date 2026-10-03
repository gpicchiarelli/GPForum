# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::ScheduledJobs;

use Carp    qw(croak);
use English qw(-no_match_vars);
use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Command::Usage;

our $VERSION = '0.001';

const my $COMMAND       => 'gpforum-scheduled-jobs';
const my $DEFAULT_LIMIT => 100;

# The application, or a code reference that builds it -- built only when work
# actually runs, so --help needs no configuration. The entry point, which is
# the composition layer, supplies it: a command does not reach up to the
# application class for it (ADR 0107).
has app    => undef;
has jobs   => undef;
has output => sub { return \*STDOUT; };

# Misuse -- an unknown option or job name, all the parser croaks for -- is the
# documented usage exit: same text, on stderr, status 2, without croak's " at
# FILE line N". A failure of the run itself -- the database gone -- is kept
# apart from it: 1 with its reason rather than the 255 of an uncaught
# exception, and under --json still a document.
sub run ( $self, @arguments ) {
    my $options = eval { return _parse_arguments(@arguments); };
    if ( !$options ) {
        return GPForum::Command::Usage->error( undef,
            GPForum::Command::Usage->trimmed($EVAL_ERROR) );
    }
    return _print_usage( $self->output ) if $options->{help};

    my $status = eval { return $self->_run($options); };
    return $status if defined $status;

    return GPForum::Command::Usage->failure( $EVAL_ERROR,
        $options->{json}
        ? ( $self->output, { command => $COMMAND, jobs => [] } )
        : () );
}

sub _run ( $self, $options ) {
    my $summary = $self->run_once($options);
    if ( $options->{json} ) {
        GPForum::Command::Usage->json( $self->output,
            _json_document($summary) );
    }
    else {
        _print_summary( $self->output, $summary );
    }

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

    my $controller = $self->_application->build_controller;
    my $jobs       = $controller->gp_scheduled_jobs;
    _give_orphan_purge_storage( $jobs, $controller );

    return $jobs;
}

# The orphan purge removes each orphan's files with its row, through the
# attachment storage, and purges nothing without one; the application's
# attachment store is built without it, having no other use for it. The
# store is the runner's own, so lending it the storage reaches nothing else.
sub _give_orphan_purge_storage ( $jobs, $controller ) {
    my $store = $jobs->attachment_store;
    return if !$store || !$store->can('storage') || $store->storage;

    $store->storage( $controller->gp_attachment_storage );

    return;
}

sub _application ($self) {
    my $app = $self->app
      or croak 'this command was built without an application';

    return ref $app eq 'CODE' ? $app->() : $app;
}

sub _parse_arguments (@arguments) {
    my %options = (
        jobs  => [],
        json  => 0,
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
    if ( $argument eq '--json' ) {
        $options->{json} = 1;
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

# The summary line as one object: a job per entry, in name order, with the
# count the line prints and, when there are any, why it did nothing and what
# went wrong.
sub _json_document ($summary) {
    my @jobs;
    for my $name ( grep { $_ ne 'ok' } sort keys %{$summary} ) {
        push @jobs, _json_job( $name, $summary->{$name} );
    }

    return {
        command => $COMMAND,
        jobs    => \@jobs,
        status  => $summary->{ok} ? 'ok' : 'fail',
    };
}

sub _json_job ( $name, $result ) {
    if ( ref $result ne 'HASH' ) {
        return { count => $result // 0, name => $name };
    }
    my %job = ( count => _job_count($result), name => $name );
    if ( exists $result->{ok} ) {
        $job{ok} = $result->{ok} ? 1 : 0;
    }
    for my $note (qw(skipped error)) {
        if ( defined $result->{$note} ) {
            $job{$note} = $result->{$note};
        }
    }
    if ( ref $result->{errors} eq 'ARRAY' ) {
        $job{errors} = scalar @{ $result->{errors} };
    }

    return \%job;
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

# The purges count what they deleted; the orphan-attachment cleanup answers
# with the deleted rows themselves. Taken as a count, they printed as
# "attachments=ARRAY(0x...)", and --json put each row -- its owner, its object
# key -- where the number belongs.
sub _job_count ($result) {
    if ( exists $result->{deleted} ) {
        return
          ref $result->{deleted} eq 'ARRAY'
          ? scalar @{ $result->{deleted} }
          : $result->{deleted};
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
      . "Usage: bin/gpforum-scheduled-jobs [--once] [--limit N] [--job NAME] [--json]\n";
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

The runner comes from the application's C<gp_scheduled_jobs>. Its
attachment store, when it has none, is given the application's attachment
storage (C<gp_attachment_storage>), through which the C<attachments> job
removes the files of the orphans it purges
(L<GPForum::Service::Attachment::Store/cleanup_orphans>). A runner passed in
as C<jobs> is used as it is.

=head1 SUBROUTINES/METHODS

=head2 run

Parses CLI options, runs one batch, and prints a summary: one line, or with
C<--json> one JSON object. Returns 0, 1 when a job or the run failed, and 2
on misuse.

=head2 run_once

Runs the selected jobs with the parsed options.

=head1 DIAGNOSTICS

An unknown option or job name prints the usage to standard error and returns
2; a run that cannot start prints its reason there and returns 1.

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
