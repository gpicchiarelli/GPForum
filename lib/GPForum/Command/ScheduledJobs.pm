# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::ScheduledJobs;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::Util qw(encode);

use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Support::Words;
use GPForum::Command::Usage;
use GPForum::Service::Operations::Findings;
use GPForum::X::Argument;
use GPForum::X::Usage;

our $VERSION = '0.001';

const my $COMMAND => 'gpforum-scheduled-jobs';

# What each job works on, as an operator calls it, and how a count of what
# it did is said: once, and more than once.
const my %JOB_WORDS => (
    attachment_backfill => 'cli.jobs.name.attachment_backfill',
    attachment_scans    => 'cli.jobs.name.attachment_scans',
    attachments         => 'cli.jobs.name.attachments',
    dead_letters        => 'cli.jobs.name.dead_letters',
    identity_tokens     => 'cli.jobs.name.identity_tokens',
    outbox_messages     => 'cli.jobs.name.outbox_messages',
    partitions          => 'cli.jobs.name.partitions',
    rate_limit_buckets  => 'cli.jobs.name.rate_limit_buckets',
    sessions            => 'cli.jobs.name.sessions',
);
const my %DONE_WORDS => (
    deleted => [ 'cli.jobs.removed_one', 'cli.jobs.removed_many' ],
    scanned => [ 'cli.jobs.scanned_one', 'cli.jobs.scanned_many' ],
);

# Why a job did nothing, or stopped, as the operator's language says it: the
# jobs give the reason in English words a journal line and --json keep, and
# the Italian line read "non eseguito (scanning is off)".
const my %REASON_WORDS => (
    'antivirus unavailable' => 'cli.jobs.reason.antivirus_unavailable',
    'failed'                => 'cli.jobs.reason.failed',
    'scanning is off'       => 'cli.jobs.reason.scanning_off',
    'unavailable'           => 'cli.jobs.reason.unavailable',
);
const my $DEFAULT_LIMIT => 100;

# Each flag sets one option to one value; --once is the only mode there is.
const my %FLAG_OPTIONS => (
    '--help' => [ help => 1 ],
    '--json' => [ json => 1 ],
    '--once' => [ once => 1 ],
);

# The application, or a code reference that builds it -- built only when work
# actually runs, so --help needs no configuration. The entry point, which is
# the composition layer, supplies it: a command does not reach up to the
# application class for it (ADR 0107).
has app    => undef;    # optional: only work that runs needs it
has jobs   => undef;    # optional: the application's own otherwise
has output => sub { return \*STDOUT; };

# A line a job in the operator's language rather than the key=value line:
# `gpforum scheduled-jobs`, the front door's verb, says what each job did,
# where bin/gpforum-scheduled-jobs keeps the line the timers' journals and
# the scripts that read them were written for.
has human => 0;
has words => sub { return GPForum::Command::Support::Words->new; };

# Misuse -- an unknown option or job name, all the parser rejects -- is the
# documented usage exit: same text, on stderr, status 2, without croak's " at
# FILE line N". A failure of the run itself -- the database gone -- is kept
# apart from it: 1 with its reason rather than the 255 of an uncaught
# exception, and under --json still a document.
sub run ( $self, @arguments ) {
    my $options;
    try {
        $options = _parse_arguments(@arguments);
    }
    catch ($error) {
        return GPForum::Command::Usage->error( undef,
            GPForum::Command::Usage->trimmed($error) );
    };

    return _print_usage( $self->output ) if $options->{help};

    my $status;
    try {
        $status = $self->_run($options);
    }
    catch ($error) {
        return GPForum::Command::Usage->failure( $error,
            $options->{json}
            ? ( $self->output, { command => $COMMAND, jobs => [] } )
            : () );
    };

    return $status;
}

sub _run ( $self, $options ) {
    my $summary = $self->run_once($options);
    if ( $options->{json} ) {
        GPForum::Command::Usage->json( $self->output,
            _json_document($summary) );
    }
    elsif ( $self->human ) {
        $self->_say_summary($summary);
    }
    else {
        _print_summary( $self->output, $summary );
    }

    # Non-zero when a job failed, so the timer unit is marked failed and can
    # alert rather than recording a clean run.
    return $summary->{ok} ? 0 : 1;
}

# The runner given, or the application's own, built only now.
sub run_once ( $self, $options ) {
    my $jobs = $self->jobs;

    # The application lives as long as the run: a controller holds it
    # weakly, and one built from an application nothing else held had
    # none by the next line -- bin/gpforum-scheduled-jobs, which the systemd
    # timer runs, died with "Can't locate object method gp_scheduled_jobs".
    my $application;
    if ( !$jobs ) {
        my $app = $self->app
          or GPForum::X::Argument->throw(
            message => 'this command was built without an application' );
        $application = ref $app eq 'CODE' ? $app->() : $app;
        my $controller = $application->build_controller;
        $jobs = $controller->gp_scheduled_jobs;

        # The orphan purge removes each orphan's files with its row, through
        # the attachment storage, and purges nothing without one; the
        # application's attachment store is built without it, having no
        # other use for it. The store is the runner's own, so lending it the
        # storage reaches nothing else.
        my $store = $jobs->attachment_store;
        if ( $store && !$store->storage ) {
            $store->storage( $controller->gp_attachment_storage );
        }
    }

    return $jobs->run(
        {
            jobs  => $options->{jobs},
            limit => $options->{limit},
        }
    );
}

sub _parse_arguments (@arguments) {
    my %options = (
        jobs  => [],
        json  => 0,
        limit => $DEFAULT_LIMIT,
    );

    while (@arguments) {
        my $argument = shift @arguments;
        if ( exists $FLAG_OPTIONS{$argument} ) {
            my ( $name, $value ) = @{ $FLAG_OPTIONS{$argument} };
            $options{$name} = $value;
        }
        elsif ( $argument eq '--limit' ) {
            $options{limit} = _positive_integer( $argument, shift @arguments );
        }
        elsif ( $argument eq '--job' ) {
            push @{ $options{jobs} }, _job_name( shift @arguments );
        }
        else {
            GPForum::X::Usage->throw(
                message => _usage("unknown option $argument") );
        }
    }

    return \%options;
}

sub _job_name ($value) {
    if ( !defined $value ) {
        GPForum::X::Usage->throw(
            message => _usage('--job requires a job name') );
    }

    require GPForum::Service::Operations::ScheduledJobs;
    my %known = map { $_ => 1 }
      @{ GPForum::Service::Operations::ScheduledJobs->new->job_names };
    if ( !$known{$value} ) {
        GPForum::X::Usage->throw( message => _usage("unknown job $value") );
    }

    return $value;
}

sub _positive_integer ( $option, $value ) {
    if ( !defined $value || $value !~ /\A [[:digit:]]+ \z/msx || $value < 1 ) {
        GPForum::X::Usage->throw(
            message => _usage("$option requires a positive integer") );
    }

    return int $value;
}

# ok first, then each job in name order: its count and, after it, what a
# count alone hides -- why the job did nothing, and what went wrong.
sub _print_summary ( $output, $summary ) {
    my @pairs;
    for my $name ( 'ok', grep { $_ ne 'ok' } sort keys %{$summary} ) {
        my $value = $summary->{$name};
        if ( ref $value ne 'HASH' ) {
            push @pairs, join q{=}, $name, $value // 0;
            next;
        }
        push @pairs, join q{=}, $name, _job_count($value);
        for my $note (qw(skipped error)) {
            if ( defined $value->{$note} ) {
                push @pairs, qq{${name}_$note="$value->{$note}"};
            }
        }
        if ( ref $value->{errors} eq 'ARRAY' ) {
            push @pairs, "${name}_errors=" . scalar @{ $value->{errors} };
        }
    }

    print {$output} join( q{ }, 'scheduled_jobs', @pairs ), "\n"
      or croak 'failed to write scheduled jobs summary';

    return;
}

# Each job on a line of its own, in the order they ran, named as an operator
# knows the data: what it removed or scanned, why it did nothing, or what
# went wrong, with the scanner's words for each file it could not scan.
sub _say_summary ( $self, $summary ) {
    my $findings = GPForum::Service::Operations::Findings->new(
        catalog => $self->words->catalog );
    for my $name ( grep { $_ ne 'ok' } sort keys %{$summary} ) {
        $findings->add( $self->_job_finding( $name, $summary->{$name} ) );
    }
    my $text = GPForum::Command::Support::ServiceEnvironment->as_read(
        $findings->human_text( summary => 0 ) );
    print { $self->output } encode( 'UTF-8', $text )
      or croak 'failed to write scheduled jobs summary';

    return;
}

sub _job_finding ( $self, $name, $result ) {
    my $job =
      exists $JOB_WORDS{$name}
      ? $self->words->text( $JOB_WORDS{$name} )
      : $name;
    if ( ref $result ne 'HASH' ) {
        $result = { ok => $result ? 1 : 0 };
    }
    my %finding = ( name => $name, status => 'ok' );

    if ( defined $result->{error}
        || ( exists $result->{ok} && !$result->{ok} && !$result->{errors} ) )
    {
        return ( %finding,
            $self->_failed( $job, $result->{error} // 'failed' ) );
    }
    if ( defined $result->{skipped} ) {
        return (
            %finding,
            message => [
                'cli.jobs.skipped',
                { job => $job, reason => $self->_reason( $result->{skipped} ) }
            ],
        );
    }

    my $count  = _job_count($result);
    my ($done) = grep { exists $result->{$_} } sort keys %DONE_WORDS;
    my @errors = @{ $result->{errors} // [] };

    return (
        %finding,
        status  => @errors ? 'fail' : 'ok',
        message => defined $done
        ? [
            $DONE_WORDS{$done}[ $count == 1 ? 0 : 1 ],
            { job => $job, count => $count }
          ]
        : [ 'cli.jobs.done', { job => $job } ],
        notes => [ map { [ 'antivirus.detail', { detail => $_ } ] } @errors ],
    );
}

# A job that stopped: what stopped it, and, for a scanner that does not
# answer, the check that says why.
sub _failed ( $self, $job, $error ) {
    my @fixes =
      $error eq 'antivirus unavailable'
      ? ( [ 'status.fix_says_why', { command => 'gpforum antivirus-check' } ] )
      : ();

    return (
        status  => 'fail',
        message => [
            'cli.jobs.failed', { job => $job, error => $self->_reason($error) }
        ],
        fixes => \@fixes,
    );
}

# A reason a job gave, in the operator's language when the catalogs know
# it; an error's own text, a database's say, as it was.
sub _reason ( $self, $reason ) {
    return
      exists $REASON_WORDS{$reason}
      ? $self->words->text( $REASON_WORDS{$reason} )
      : $reason;
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
    return GPForum::Command::Usage->help( $output, _usage() );
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
