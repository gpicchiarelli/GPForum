# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::OutboxDispatch;

use strict;
use warnings;

use Carp    qw(croak);
use English qw(-no_match_vars);
use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Command::Usage;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT         => 100;
const my $DEFAULT_SLEEP_SECONDS => 5;

# The application, or a code reference that builds it -- built only when work
# actually runs, so --help needs no configuration. The entry point, which is
# the composition layer, supplies it: a command does not reach up to the
# application class for it (ADR 0107).
has app        => undef;
has dispatcher => undef;
has output     => sub { return \*STDOUT; };
has sleeper    => sub {
    return sub {
        my ($seconds) = @_;

        sleep $seconds;

        return;
    };
};

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

    my $stop_requested = 0;
    local $SIG{INT} = local $SIG{TERM} = sub {
        $stop_requested = 1;
    };

    my $iterations = 0;
    while (1) {
        my $summary = $self->dispatch_once( $options->{limit} );
        _print_summary( $self->output, $summary );

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
      or croak 'this command was built without an application';

    return ref $app eq 'CODE' ? $app->() : $app;
}

sub _parse_arguments (@arguments) {
    my %options = (
        limit         => $DEFAULT_LIMIT,
        once          => 1,
        sleep_seconds => $DEFAULT_SLEEP_SECONDS,
    );

    while (@arguments) {
        my $argument = shift @arguments;
        if ( $argument eq '--help' ) {
            $options{help} = 1;
        }
        elsif ( $argument eq '--once' ) {
            $options{once} = 1;
        }
        elsif ( $argument eq '--loop' ) {
            $options{once} = 0;
        }
        elsif ( $argument eq '--limit' ) {
            $options{limit} = _positive_integer( $argument, shift @arguments );
        }
        elsif ( $argument eq '--sleep' ) {
            $options{sleep_seconds} =
              _positive_integer( $argument, shift @arguments );
        }
        elsif ( $argument eq '--max-iterations' ) {
            $options{max_iterations} =
              _positive_integer( $argument, shift @arguments );
        }
        else {
            croak _usage("unknown option $argument");
        }
    }

    return \%options;
}

sub _positive_integer ( $option, $value ) {
    croak _usage("$option requires a positive integer")
      if !defined $value || $value !~ /\A [[:digit:]]+ \z/msx || $value < 1;

    return int $value;
}

sub _print_summary ( $output, $summary ) {
    print {$output} join( q{ },
        'outbox_dispatch',
        map { $_ . q{=} . ( defined $summary->{$_} ? $summary->{$_} : 0 ) }
          qw(selected dispatched failed dead_lettered) ),
      "\n"
      or croak 'failed to write outbox dispatch summary';

    return;
}

sub _print_usage ($output) {
    print {$output} _usage() or croak 'failed to write outbox dispatch usage';

    return 0;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _usage ( $message = undef ) {
    return ( defined $message ? "$message\n" : q{} )
      . "Usage: bin/gpforum-outbox-dispatch [--once|--loop] [--limit N] [--sleep N] [--max-iterations N]\n";
}

1;
