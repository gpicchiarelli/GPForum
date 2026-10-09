# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::OutboxDispatch;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::Util qw(encode);

use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Support::Words;
use GPForum::Command::Usage;
use GPForum::X::Argument;
use GPForum::X::Usage;

our $VERSION = '0.001';

const my $COMMAND               => 'gpforum-outbox-dispatch';
const my $DEFAULT_LIMIT         => 100;
const my $DEFAULT_SLEEP_SECONDS => 5;

# The dispatcher's summary, in the order the line prints it: the first four
# where a reader of the line has always found them, then the messages
# acknowledged and the claims another worker took (OUTBOX_LIFECYCLE.md,
# Claims and Leases).
const my @COUNT_KEYS =>
  qw(selected dispatched failed dead_lettered acknowledged lost);

# The switches, with the option each sets and to what, and the options that
# take a positive count, with the key the count is stored under.
const my %SWITCH => (
    '--help' => [ help => 1 ],
    '--once' => [ once => 1 ],
    '--loop' => [ once => 0 ],
    '--json' => [ json => 1 ],
);
const my %COUNT_OPTION => (
    '--limit'          => 'limit',
    '--sleep'          => 'sleep_seconds',
    '--max-iterations' => 'max_iterations',
);

# The application, or a code reference that builds it -- built only when work
# actually runs, so --help needs no configuration. The entry point, which is
# the composition layer, supplies it: a command does not reach up to the
# application class for it (ADR 0107).
has app        => undef;    # optional: only work that runs needs it
has dispatcher => undef;    # optional: the application's own otherwise
has output     => sub { return \*STDOUT; };

# Sentences in the operator's language rather than the key=value line:
# `gpforum outbox`, the front door's verb, says what it sent, as every verb
# does, where bin/gpforum-outbox-dispatch keeps the line the units' journals
# and the scripts that read them were written for.
has human   => 0;
has words   => sub { return GPForum::Command::Support::Words->new; };
has sleeper => sub {
    return sub {
        my ($seconds) = @_;

        sleep $seconds;

        return;
    };
};

# Misuse is the documented usage exit, 2, with the usage on stderr: an
# unknown option used to die with status 255, since its text starts with the
# complaint rather than the usage line. A failure of the dispatch itself --
# the database gone -- exits 1 with its reason, and under --json still prints
# a document.
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
        return GPForum::Command::Usage->failure(
            $error,
            $options->{json}
            ? (
                $self->output,
                { command => $COMMAND, map { $_ => 0 } @COUNT_KEYS }
              )
            : ()
        );
    };

    return $status;
}

sub _run ( $self, $options ) {
    my $stop_requested = 0;
    local $SIG{INT} = local $SIG{TERM} = sub {
        $stop_requested = 1;
    };

    if ( $self->human && !$options->{json} && !$options->{once} ) {
        $self->_say(
            $self->_said(
                'cli.outbox.watching', { seconds => $options->{sleep_seconds} }
            )
        );
    }

    my $iterations = 0;
    while (1) {
        my $summary = $self->dispatch_once( $options->{limit} );
        $self->_report( $summary, $options );

        $iterations++;
        last if $options->{once};
        last if $stop_requested;
        last
          if defined $options->{max_iterations}
          && $iterations >= $options->{max_iterations};

        # Sleep only once the backlog is drained. A full batch means more is
        # waiting, and sleeping after every batch capped the dispatcher at
        # --limit messages per --sleep seconds however far behind it was,
        # holding realtime, notifications and cache purges behind any slow
        # message. A failed message is not claimed again before its backoff,
        # so a batch of failures cannot make this spin.
        if ( ( $summary->{selected} // 0 ) < $options->{limit} ) {
            $self->sleeper->( $options->{sleep_seconds} );
        }
    }

    return 0;
}

sub dispatch_once ( $self, $limit ) {
    return $self->_dispatcher->dispatch_pending($limit);
}

sub _dispatcher ($self) {
    return $self->dispatcher if $self->dispatcher;

    return $self->_application->build_controller->gp_outbox_dispatcher;
}

sub _application ($self) {
    my $app = $self->app
      or GPForum::X::Argument->throw(
        message => 'this command was built without an application' );

    return ref $app eq 'CODE' ? $app->() : $app;
}

sub _parse_arguments (@arguments) {
    my %options = (
        json          => 0,
        limit         => $DEFAULT_LIMIT,
        once          => 1,
        sleep_seconds => $DEFAULT_SLEEP_SECONDS,
    );

    while (@arguments) {
        my $argument = shift @arguments;
        if ( exists $SWITCH{$argument} ) {
            my ( $name, $value ) = @{ $SWITCH{$argument} };
            $options{$name} = $value;
        }
        elsif ( exists $COUNT_OPTION{$argument} ) {
            $options{ $COUNT_OPTION{$argument} } =
              _positive_integer( $argument, shift @arguments );
        }
        else {
            GPForum::X::Usage->throw(
                message => _usage("unknown option $argument") );
        }
    }

    return \%options;
}

sub _positive_integer ( $option, $value ) {
    if ( !defined $value || $value !~ /\A [[:digit:]]+ \z/msx || $value < 1 ) {
        GPForum::X::Usage->throw(
            message => _usage("$option requires a positive integer") );
    }

    return int $value;
}

# One object per batch, so --loop --json reads as JSON Lines. A message that
# failed is retried after its backoff, as the line says, so the batch's status
# is ok: the counts carry what happened.
sub _json_document ($summary) {
    return {
        command => $COMMAND,
        status  => 'ok',
        map { $_ => $summary->{$_} // 0 } @COUNT_KEYS,
    };
}

# A batch's summary: one JSON object, the sentences of the front door's
# verb, or the line bin/gpforum-outbox-dispatch prints.
sub _report ( $self, $summary, $options ) {
    if ( $options->{json} ) {
        GPForum::Command::Usage->json( $self->output,
            _json_document($summary) );
    }
    elsif ( $self->human ) {
        $self->_say_summary( $summary, $options );
    }
    else {
        _print_summary( $self->output, $summary );
    }

    return;
}

# A batch as an operator reads it: what was sent, what waits for a retry,
# what was given up on and what another worker took over, then where to see
# why a message was given up on. A loop says nothing of a batch that found
# nothing, which it looks for every few seconds; --once always answers.
sub _say_summary ( $self, $summary, $options ) {
    my %count = map { $_ => $summary->{$_} // 0 } @COUNT_KEYS;
    if ( !$count{selected} ) {
        if ( $options->{once} ) {
            $self->_say( $self->_said('cli.outbox.nothing') );
        }
        return;
    }

    my @parts = (
        $self->_counted(
            $count{dispatched}, 'cli.outbox.sent_one',
            'cli.outbox.sent_many'
        )
    );
    if ( $count{failed} ) {
        push @parts,
          $self->_said( 'cli.outbox.retry', { count => $count{failed} } );
    }
    if ( $count{dead_lettered} ) {
        push @parts,
          $self->_counted( $count{dead_lettered}, 'cli.outbox.dead_one',
            'cli.outbox.dead_many' );
    }
    if ( $count{lost} ) {
        push @parts,
          $self->_counted( $count{lost}, 'cli.outbox.lost_one',
            'cli.outbox.lost_many' );
    }
    $self->_say( join( q{; }, @parts ) . q{.} );
    if ( $count{dead_lettered} ) {
        $self->_say(
            $self->_said(
                'cli.next', { step => $self->_said('cli.outbox.next_dead') }
            )
        );
    }

    return;
}

sub _counted ( $self, $count, $one, $many ) {
    return $self->_said( $count == 1 ? $one : $many, { count => $count } );
}

sub _said ( $self, $key, $parameters = {} ) {
    return $self->words->text( $key, $parameters );
}

# A gpforum command a line offers reads the file this run read.
sub _say ( $self, $line ) {
    my $read = GPForum::Command::Support::ServiceEnvironment->as_read($line);
    print { $self->output } encode( 'UTF-8', "$read\n" )
      or croak 'failed to write outbox dispatch summary';

    return;
}

sub _print_summary ( $output, $summary ) {
    print {$output} join( q{ },
        'outbox_dispatch',
        map { $_ . q{=} . ( defined $summary->{$_} ? $summary->{$_} : 0 ) }
          @COUNT_KEYS ),
      "\n"
      or croak 'failed to write outbox dispatch summary';

    return;
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
      . "Usage: bin/gpforum-outbox-dispatch [--once|--loop] [--limit N] [--sleep N] [--max-iterations N] [--json]\n";
}

1;
