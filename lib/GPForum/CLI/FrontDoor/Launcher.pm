# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::CLI::FrontDoor::Launcher;

use Carp qw(croak);
use Const::Fast;
use Cwd        qw(getcwd);
use English    qw(-no_match_vars);
use List::Util qw(any first min);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File   qw(path);
use Mojo::Loader qw(load_class);
use Mojo::Util   qw(encode);

use GPForum::CLI::FrontDoor::Help;
use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Support::Verbs;
use GPForum::Command::Support::Words;
use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::X::Config;

our $VERSION = '0.001';

const my $FRONT_DOOR => 'gpforum';

# The verbs that work on this forum, as the service does, run from the code
# directory the service's units run from: migrations/ and a relative
# attachment root are read from there. The benchmarks, seeds, drills and
# evidence commands keep the directory they were typed in, since the files
# they are given are relative to it.
const my %FROM_CODE_DIRECTORY => map { $_ => 1 } qw(setup run check maintain);

# A suggestion for a mistyped verb is offered only when it is this close: a
# third of what was typed, as for a mistyped setting.
const my $SUGGESTION_PER_CHARS => 3;

# The commands with an --env-file of their own: staging-host-verify's is the
# file it checks, not one the front door reads.
const my %OWNS_ENV_FILE => map { $_ => 1 } qw(staging_host_verify);

# The verbs that write the environment file rather than read it: gpforum
# setup makes it, so a file named with --env-file, before or after the verb,
# need not exist yet, and it is handed to the verb, whole, to write.
const my %WRITES_ENV_FILE => map { $_ => 1 } qw(setup);

# The directory the operator typed the verb in, before a verb that works on
# this forum moved to the code directory: a path they gave relative to it,
# such as gpforum service print --to, starts there.
my $TYPED_IN;

# The application the commands that need it start.
has application => 'GPForum';

# The checkout bin/gpforum belongs to.
has root => sub {
    return path(__FILE__)->to_abs->dirname->dirname->dirname->dirname->dirname;
};

has words => sub { return GPForum::Command::Support::Words->new; };

# Runs `gpforum [--env-file FILE] VERB [ARGUMENTS]` and returns the exit
# status: 0, the verb's own, 2 for a command line it cannot read, 78 for
# settings it cannot use.
sub run ( $self, @arguments ) {
    my $options = $self->_global_options( \@arguments );
    return $options if !ref $options;

    my $typed = shift @arguments;
    if ( !defined $typed || $typed eq 'help' ) {
        return $self->help( $options, @arguments );
    }

    my $verb = $self->resolve($typed);
    return $self->_unknown($typed) if !$verb;

    # `gpforum migrate --env-file FILE`, as an operator often types it: the
    # verb's parser answered that --env-file is not one of its options.
    my $misused = $self->_env_file_after( $verb, \@arguments, $options );
    return $misused if defined $misused;
    return $self->_write_env_file( $verb, $typed, $options, @arguments )
      if exists $WRITES_ENV_FILE{ $verb->{name} };

    # A verb that runs the application explains itself without building it,
    # so its help needs no settings, as every other verb's does.
    if ( $verb->{needs_application}
        && GPForum::Command::Usage->wants_help(@arguments) )
    {
        return $self->help( $options, $typed );
    }

    local $PROGRAM_NAME = "$FRONT_DOOR $typed";
    my $status = $self->_load_environment($options);
    return $status if defined $status;

    return $self->_run_verb( $verb, @arguments );
}

# A verb that writes the environment file, run without reading it first,
# with the file named on the command line given to it as an absolute path:
# the front door has moved to the code directory by the time it runs.
sub _write_env_file ( $self, $verb, $typed, $options, @arguments ) {
    local $PROGRAM_NAME = "$FRONT_DOOR $typed";
    my @file =
      defined $options->{env_file}
      ? ( '--env-file', $options->{env_file} )
      : ();

    return $self->_run_verb( $verb, @file, @arguments );
}

# The verb, with the settings read: from the code directory when it works on
# this forum, through the application when it needs one.
sub _run_verb ( $self, $verb, @arguments ) {
    my $group = $verb->{group};
    if ( defined $group && exists $FROM_CODE_DIRECTORY{$group} ) {
        $TYPED_IN = getcwd();
        my $root = $self->root;
        chdir $root or croak "cannot enter $root: $OS_ERROR";
    }
    if ( $verb->{needs_application} ) {
        return $self->_start_application( $verb, @arguments );
    }

    return $verb->{class}->new->run(@arguments) // 0;
}

sub typed_in ($class) {
    return $TYPED_IN;
}

# `gpforum help`, `gpforum help --all` and `gpforum help VERB`.
sub help ( $self, $options, @arguments ) {
    my $all = grep { $_ eq '--all' } @arguments;
    my ($typed) = grep { $_ ne '--all' } @arguments;
    my $help =
      GPForum::CLI::FrontDoor::Help->new(
        environment => $self->_environment($options) );
    return $self->_print( $help->render($all) ) if !defined $typed;

    my $verb = $self->resolve($typed);
    return $self->_unknown($typed) if !$verb;

    local $PROGRAM_NAME = "$FRONT_DOOR $typed";
    my $usage =
      $verb->{class}->new->usage =~ s/\b APPLICATION \b/$FRONT_DOOR/grmsx;

    return $self->_print( GPForum::Command::Usage->as_invoked($usage) );
}

# What a typed verb runs: { class, group, needs_application }, or undef. A
# verb of the table first; then a command by its own name, dashes or
# underscores, as Mojolicious read them (`gpforum outbox-dispatch`,
# `gpforum search_rebuild`); then one of Mojolicious's own.
sub resolve ( $self, $typed ) {
    return undef if $typed !~ /\A [[:lower:]] [[:lower:][:digit:]_-]* \z/msx;

    my $listed = GPForum::Command::Support::Verbs->find($typed);
    my $name   = $listed ? $listed->{command} : $typed =~ tr/-/_/r;
    my $verb   = $listed // first { $_->{command} eq $name }
      @{ GPForum::Command::Support::Verbs->verbs };

    my $class = "GPForum::CLI::$name";
    if ( _is_command($class) ) {
        return {
            class             => $class,
            group             => $verb ? $verb->{group} : undef,
            name              => $name,
            needs_application =>
              ( $verb && ( $verb->{needs} // q{} ) eq 'application' ) ? 1 : 0,
        };
    }
    if ( any { $_ eq $name } @{ GPForum::CLI::FrontDoor::Help->framework } ) {
        my $framework = GPForum::CLI::FrontDoor::Help->framework_class($name);
        return undef if !_is_command($framework);
        return {
            class             => $framework,
            group             => undef,
            name              => $name,
            needs_application => 1,
        };
    }

    return undef;
}

# --env-file FILE (or --env-file=FILE) and --help, before the verb. The
# options that follow the verb are the verb's own: staging-host-verify takes
# an --env-file of its own, which is a file it checks, not one it reads.
sub _global_options ( $self, $arguments ) {
    my %options;
    while ( @{$arguments} && $arguments->[0] =~ /\A -/msx ) {
        my $argument = shift @{$arguments};
        if ( $argument eq '--help' || $argument eq '-h' ) {
            unshift @{$arguments}, 'help';
            last;
        }
        my ( $option, $value ) =
          $argument =~ /\A (--env-file) (?: = (.*) )? \z/msx;
        if ( !defined $option ) {
            return $self->_misuse( 'cli.front_door.global_option',
                { option => $argument } );
        }
        $value //= shift @{$arguments};
        if ( !defined $value || !length $value ) {
            return $self->_misuse( 'cli.misuse.missing_value',
                { option => $option } );
        }
        $options{env_file} = path($value)->to_abs->to_string;
    }

    return \%options;
}

# An --env-file given after the verb, taken out of the verb's arguments as
# the front door's own when none came before it and the verb has none of its
# own. Returns the exit status of a misuse, or undef.
sub _env_file_after ( $self, $verb, $arguments, $options ) {
    return undef
      if exists $options->{env_file} || exists $OWNS_ENV_FILE{ $verb->{name} };

    my @kept;
    while ( @{$arguments} ) {
        my $argument = shift @{$arguments};
        my ( $option, $value ) =
          $argument =~ /\A (--env-file) (?: = (.*) )? \z/msx;
        if ( !defined $option || exists $options->{env_file} ) {
            push @kept, $argument;
            next;
        }
        $value //= shift @{$arguments};
        if ( !defined $value || !length $value ) {
            return $self->_misuse( 'cli.misuse.missing_value',
                { option => $option } );
        }
        $options->{env_file} = path($value)->to_abs->to_string;
    }
    @{$arguments} = @kept;

    return undef;
}

sub _environment ( $self, $options ) {
    return GPForum::Command::Support::ServiceEnvironment->new(
        file => $options->{env_file} );
}

# The settings the service reads, read before anything else so the verb
# sees what the service sees.
sub _load_environment ( $self, $options ) {
    try {
        $self->_environment($options)->load;
    }
    catch ($error) {
        my $invalid = GPForum::X::Config->caught($error);
        die $error if !$invalid;    ## no critic (ErrorHandling::RequireCarping) -- rethrows the caught error as it was raised

        $self->_complain( $invalid->message );
        return $GPForum::Command::Usage::EXIT_CONFIG;
    };

    return undef;
}

# Mojolicious's commands, `gpforum start`, and the workers that take their
# dispatcher and jobs from it (`gpforum outbox`, `gpforum scheduled-jobs`)
# run the web application: a command built without it has Mojolicious's
# placeholder application, which has none of GPForum's helpers. Its
# settings are checked first, so a wrong one is reported as every other
# command reports it -- all of them at once, naming the file this command
# read -- rather than by the application's start-up. That includes the one
# the start-up adds of its own: TLS to an SMTP server that this Perl cannot
# speak (GPForum::Config::assert_smtp_tls).
sub _start_application ( $self, $verb, @arguments ) {
    try {
        GPForum::Config->from_environment->assert_smtp_tls;
    }
    catch ($error) {
        return GPForum::Command::Usage->failure($error);
    };

    require Mojolicious::Commands;
    Mojolicious::Commands->start_app( $self->application, $verb->{name},
        @arguments );

    return 0;
}

sub _unknown ( $self, $typed ) {
    my @lines =
      ( $self->_said( 'cli.front_door.unknown', { command => $typed } ) );
    my $suggestion = $self->_nearest($typed);
    if ( defined $suggestion ) {
        push @lines,
          $self->_said( 'config.did_you_mean',
            { suggestion => "$FRONT_DOOR $suggestion" } );
    }
    push @lines, $self->_said('cli.front_door.see_help');
    $self->_complain( join "\n", @lines );

    return $GPForum::Command::Usage::EXIT_USAGE;
}

# The verb closest to what was typed, by edits, or undef when none is close.
sub _nearest ( $self, $typed ) {
    my %distance =
      map  { $_->{verb} => _distance( $typed, $_->{verb} ) }
      grep { _is_command( 'GPForum::CLI::' . $_->{command} ) }
      @{ GPForum::Command::Support::Verbs->verbs };
    my ($nearest) =
      sort { $distance{$a} <=> $distance{$b} || $a cmp $b } keys %distance;
    return undef if !defined $nearest;

    my $allowed = int( length($typed) / $SUGGESTION_PER_CHARS ) || 1;
    return $distance{$nearest} <= $allowed ? $nearest : undef;
}

# Levenshtein distance: the fewest single-character edits from one to the
# other.
sub _distance ( $from, $to ) {
    my @previous = 0 .. length $to;
    for my $i ( 1 .. length $from ) {
        my @current = ($i);
        for my $j ( 1 .. length $to ) {
            my $cost =
              substr( $from, $i - 1, 1 ) eq substr( $to, $j - 1, 1 ) ? 0 : 1;
            push @current,
              min(
                $previous[$j] + 1,
                $current[ $j - 1 ] + 1,
                $previous[ $j - 1 ] + $cost
              );
        }
        @previous = @current;
    }

    return $previous[-1];
}

sub _misuse ( $self, $key, $parameters ) {
    $self->_complain(
        join "\n",
        $self->_said( $key, $parameters ),
        $self->_said('cli.front_door.see_help')
    );

    return $GPForum::Command::Usage::EXIT_USAGE;
}

sub _is_command ($class) {
    my $error = load_class($class);
    return 0   if $error && !ref $error;
    die $error if ref $error;              ## no critic (ErrorHandling::RequireCarping) -- a command that does not compile is the programmer's to see, as it was raised

    return $class->isa('Mojolicious::Command') ? 1 : 0;
}

sub _print ( $self, $text ) {
    print encode( 'UTF-8', $text ) or croak 'failed to write help';

    return $GPForum::Command::Usage::EXIT_OK;
}

sub _complain ( $self, $text ) {
    print {*STDERR} encode( 'UTF-8', "$text\n" )
      or croak 'failed to write to standard error';

    return;
}

sub _said ( $self, $key, $parameters = {} ) {
    return $self->words->text( $key, $parameters );
}

1;

__END__

=head1 NAME

GPForum::CLI::FrontDoor::Launcher - What C<gpforum> does with its command
line.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::CLI::FrontDoor::Launcher->new->run(@ARGV);

=head1 DESCRIPTION

C<bin/gpforum>, the front door: C<gpforum [--env-file FILE] VERB
[ARGUMENTS]>. It reads the environment file the service reads
(L<GPForum::Command::Support::ServiceEnvironment>), with the process
environment first; runs the verb's command from the code directory, as the
service's units do; and answers C<gpforum help> with help of its own
(L<GPForum::CLI::FrontDoor::Help>). Every C<bin/gpforum-*> entrypoint's
command answers to its verb (L<GPForum::Command::Support::Verbs>) and to its
old name, and Mojolicious's own commands still run, C<daemon> as C<gpforum
start --foreground>.

=head1 SUBROUTINES/METHODS

=head2 run

Takes the command line and returns the exit status: the verb's own, 2 for an
unknown verb (with the nearest one suggested) or option, 78 for an
environment file or settings it cannot use.

=head2 typed_in

Class method. The directory the operator typed a verb in, when the front
door then moved to the code directory to run it; undef otherwise.

=head2 help

Takes the global options and what followed C<help>: nothing, C<--all>, or
a verb, whose own usage it prints. Returns the exit status.

=head2 resolve

Takes a typed verb and returns what runs it -- C<class>, C<name>, C<group>
and C<needs_application> -- or undef.

=head1 DIAGNOSTICS

What it says follows the operator's language
(L<GPForum::Command::Support::Words>).

=head1 CONFIGURATION AND ENVIRONMENT

Reads the host's environment file, or the one given with C<--env-file>,
into C<%ENV>, under the names C<%ENV> already holds.

=head1 DEPENDENCIES

L<Mojo::Loader>, L<Mojolicious::Commands> for the commands that start the
application, L<GPForum::Config>, L<GPForum::CLI::FrontDoor::Help>,
L<GPForum::Command::Support::ServiceEnvironment>,
L<GPForum::Command::Support::Verbs>, L<GPForum::Command::Usage>.

=head1 INCOMPATIBILITIES

Mojolicious's C<--home> and C<-m>/C<--mode> are not front-door options: the
mode is C<GPFORUM_ENV>, which the application always read instead.

=head1 BUGS AND LIMITATIONS

C<--env-file> goes before the verb, or after it for every verb but
C<staging-host-verify>, whose own C<--env-file> is the file it checks.
C<setup> writes the file rather than reading it, so the file it is given
need not exist yet.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
