# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

## no critic (NamingConventions::Capitalization)
# Lowercase on purpose: the front door and Mojolicious derive the command an
# operator types from this class's basename, so GPForum::CLI::Start would be
# invoked as `gpforum Start`.
package GPForum::CLI::start;
## use critic

use Const::Fast;
use Mojo::Base 'Mojolicious::Command', -signatures;
use v5.40;
use Carp       qw(croak);
use English    qw(-no_match_vars);
use List::Util qw(any);
use POSIX      ();
use Mojo::URL;
use Mojo::Util qw(encode);

use GPForum::CLI::FrontDoor::Carton;
use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Support::Words;
use GPForum::Command::Usage;

our $VERSION = '0.001';

const my $LISTEN => 'http://127.0.0.1:3000';

# The schemes Mojolicious's daemon listens on.
const my $SCHEME => qr/\A (?: https? | http[+]unix ) \z/msx;

# Mojo::IOLoop's words for an address it could not take, with the reason the
# system gave; Command::Usage->trimmed takes the file and line off first.
const my $CANNOT_LISTEN =>
  qr/\A Can't [ ] create [ ] listen [ ] socket: [ ] (.+) \z/msx;

# `gpforum start --foreground`: Mojolicious's daemon under a name an operator
# reads, for a development checkout. A server runs GPForum under its service
# manager, and `gpforum start` without --foreground says how.
#
# `gpforum start --service` is what the service manager runs: Hypnotoad, the
# production server, on bin/gpforum, from the dependencies this checkout
# installed -- detached, as systemd's Type=forking waits for, or with
# --foreground in the foreground, as launchd and FreeBSD's daemon(8)
# supervise it. The units then run bin/gpforum alone, which finds its Perl
# and its dependencies itself, and script/ stays the maintainers' (owner
# decision D9).
has description => 'Run the forum in this terminal, for development';
has usage       => sub ($self) { return _usage(); };

# Replaces this process with a program, an argument list; a test gives its
# own.
has replace => sub {
    return sub (@command) {
        exec { $command[0] } @command
          or croak "cannot run $command[1]: $OS_ERROR";
    };
};

# The checkout bin/gpforum belongs to, whose local/ holds Hypnotoad.
has root => sub { return GPForum::CLI::FrontDoor::Carton->root; };

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->help( \*STDOUT, _usage() )
      if GPForum::Command::Usage->wants_help(@arguments);

    my ( $foreground, $as_service, $listen ) = ( 0, 0, $LISTEN );
    my $words = GPForum::Command::Support::Words->new;
    while (@arguments) {
        my $argument = shift @arguments;
        if ( $argument eq '--foreground' ) {
            $foreground = 1;
            next;
        }
        if ( $argument eq '--service' ) {
            $as_service = 1;
            next;
        }
        if ( $argument eq '--listen' && @arguments ) {
            $listen = shift @arguments;
            next if ( Mojo::URL->new($listen)->scheme // q{} ) =~ $SCHEME;

            return GPForum::Command::Usage->front_door(
                GPForum::Command::Usage->error(
                    $words->text(
                        'cli.misuse.value',
                        { option => '--listen', value => $listen }
                    ),
                    _usage()
                )
            );
        }
        return GPForum::Command::Usage->front_door(
            GPForum::Command::Usage->error(
                $words->text(
                    $argument eq '--listen'
                    ? 'cli.misuse.missing_value'
                    : 'cli.misuse.unknown_option',
                    { option => $argument }
                ),
                _usage()
            )
        );
    }
    return $self->_hypnotoad( $words, $foreground ) if $as_service;
    if ( !$foreground ) {
        my $service = GPForum::Command::Support::ServiceEnvironment->new;
        return GPForum::Command::Usage->front_door(
            GPForum::Command::Usage->error(
                $words->text(
                    'cli.start.foreground',
                    {
                        start => $service->start_command
                          // $words->text('cli.start_service')
                    }
                ),
                _usage()
            )
        );
    }

    try {
        $self->app->commands->run( 'daemon', '--listen', $listen );
    }
    catch ($error) {
        return GPForum::Command::Usage->front_door(
            _cannot_listen( $words, $listen, $error ) );
    };

    return 0;
}

# Hypnotoad on bin/gpforum, in place of this process, so the service manager
# supervises the process it started: its own script in local/bin, run by
# this Perl with local/ on PERL5LIB and the file read in GPFORUM_ENV_FILE,
# which Hypnotoad's own restarts -- `exec $^X, HYPNOTOAD_EXE` -- inherit.
sub _hypnotoad ( $self, $words, $foreground ) {
    my $root      = $self->root;
    my $hypnotoad = "$root/local/bin/hypnotoad";
    if ( !-f $hypnotoad ) {
        my $sentence =
          $words->text( 'cli.start.no_hypnotoad', { file => $hypnotoad } );
        print {*STDERR} encode( 'UTF-8', "$sentence\n" )
          or croak 'failed to write start failure';
        return $GPForum::Command::Usage::EXIT_FAILURE;
    }

    # The file the front door read, which Hypnotoad's bin/gpforum reads in
    # place of the host's: a unit printed for another file names it with
    # --env-file, and the service, and what watches it, read that one.
    my $read = GPForum::Command::Support::ServiceEnvironment->loaded;
    if ( defined $read ) {
        $ENV{GPFORUM_ENV_FILE} = $read;    ## no critic (Variables::RequireLocalizedPunctuationVars) -- Hypnotoad, run in place of this process, reads it
    }

    my $library  = "$root/local/lib/perl5";
    my @searched = split /:/msx, $ENV{PERL5LIB} // q{};
    if ( -d $library && !any { $_ eq $library } @searched ) {
        $ENV{PERL5LIB} = join q{:}, $library, $ENV{PERL5LIB} // ();    ## no critic (Variables::RequireLocalizedPunctuationVars) -- Hypnotoad, run in place of this process, reads it
    }
    $self->replace->(
        $EXECUTABLE_NAME, $hypnotoad, ( $foreground ? '-f' : () ),
        "$root/bin/gpforum"
    );

    return 0;
}

# An address the daemon could not listen on -- one another process holds,
# one this host does not have -- said with what to do, and status 1. It
# stopped with Mojo::IOLoop's own text, a library file and line, and the
# system's error number as the exit status: 48 on macOS, 98 on Linux.
sub _cannot_listen ( $words, $listen, $error ) {
    my ($reason) = GPForum::Command::Usage->trimmed($error) =~ $CANNOT_LISTEN;
    return GPForum::Command::Usage->failure($error) if !defined $reason;

    # Held by another process: the next port on the same host is free more
    # often than not. Anything else: the address the forum listens on by
    # default.
    my $url  = Mojo::URL->new($listen);
    my $busy = $reason eq _system_error( POSIX::EADDRINUSE() )
      && defined $url->port;
    my $other    = $busy ? $url->clone->port( $url->port + 1 ) : $LISTEN;
    my $sentence = $words->text(
        $busy ? 'cli.start.busy' : 'cli.start.cannot_listen',
        {
            listen => $listen,
            other  => "gpforum start --foreground --listen $other",
            reason => $reason,
        }
    );
    my $read =
      GPForum::Command::Support::ServiceEnvironment->as_read($sentence);
    print {*STDERR} encode( 'UTF-8', "$read\n" )
      or croak 'failed to write start failure';

    return $GPForum::Command::Usage::EXIT_FAILURE;
}

# The system's words for an error number, as $! says them.
sub _system_error ($number) {
    local $OS_ERROR = $number;

    return "$OS_ERROR";
}

sub _usage {
    return <<"USAGE";
Usage: gpforum start --foreground [--listen URL]
       gpforum start --service [--foreground]

Runs the forum in this terminal until Ctrl-C, for development, listening on
$LISTEN unless --listen says otherwise. A server runs GPForum under
its service manager instead: gpforum start without --foreground says how.

  --foreground     run here, in this terminal
  --listen URL     where to listen (default $LISTEN)
  --service        run Hypnotoad, the production server, as the service
                   files do: detached, or with --foreground in the
                   foreground of the service manager
  --help           show this help

gpforum daemon, Mojolicious's own command, takes every option it has.
USAGE
}

1;
