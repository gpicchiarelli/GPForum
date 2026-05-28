package GPForum::Command::OutboxDispatch;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT         => 100;
const my $DEFAULT_SLEEP_SECONDS => 5;

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

sub run {
    my ( $self, @arguments ) = @_;

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

        $self->sleeper->( $options->{sleep_seconds} );
    }

    return 0;
}

sub dispatch_once {
    my ( $self, $limit ) = @_;

    return $self->_dispatcher->dispatch_pending($limit);
}

sub _dispatcher {
    my ($self) = @_;

    return $self->dispatcher if $self->dispatcher;

    require GPForum;
    my $application = $self->app || GPForum->new;
    return $application->build_controller->gp_outbox_dispatcher;
}

sub _parse_arguments {
    my (@arguments) = @_;

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

sub _positive_integer {
    my ( $option, $value ) = @_;

    croak _usage("$option requires a positive integer")
      if !defined $value || $value !~ /\A [[:digit:]]+ \z/msx || $value < 1;

    return int $value;
}

sub _print_summary {
    my ( $output, $summary ) = @_;

    print {$output} join( q{ },
        'outbox_dispatch',
        map { $_ . q{=} . ( defined $summary->{$_} ? $summary->{$_} : 0 ) }
          qw(selected dispatched failed dead_lettered) ),
      "\n"
      or croak 'failed to write outbox dispatch summary';

    return;
}

sub _print_usage {
    my ($output) = @_;

    print {$output} _usage() or croak 'failed to write outbox dispatch usage';

    return 0;
}

sub _usage {
    my ($message) = @_;

    return ( defined $message ? "$message\n" : q{} )
      . "Usage: bin/gpforum-outbox-dispatch [--once|--loop] [--limit N] [--sleep N] [--max-iterations N]\n";
}

1;
