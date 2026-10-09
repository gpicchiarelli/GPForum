# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::Usage;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use IO::Handle    ();
use JSON::MaybeXS ();
use List::Util    qw(any);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::Util qw(encode);

use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Support::Verbs;
use GPForum::Command::Support::Words;
use GPForum::Service::Operations::DatabaseFailure;
use GPForum::Service::Admin::Settings;
use GPForum::Service::Operations::EvidenceMeta qw(evidence_finalize);
use GPForum::X::Argument;
use GPForum::X::Config;
use GPForum::X::Usage;

our $VERSION = '0.001';

# The exit-code contract every GPForum entrypoint honours.
#
# Before this, --help was a fatal error on eight of them: `croak _usage()`
# died, so the operator got the usage text with " at bin/... line 17." glued to
# the end and an exit status of 255. Asking a program how to use it is not an
# error, and 255 is what Perl reports for an uncaught exception, not a status
# anyone can branch on.
const our $EXIT_OK      => 0;
const our $EXIT_FAILURE => 1;
const our $EXIT_USAGE   => 2;

# sysexits.h's EX_CONFIG, "configuration error": settings the command cannot
# use, which an operator fixes in the environment file rather than by running
# the command again. bin/gpforum stopped with it and every other command with
# 1, so a supervisor or a script could not tell a wrong setting from a failed
# run unless it came in through one door.
const our $EXIT_CONFIG => 78;

# What the front door calls itself; a program invoked as "gpforum VERB" came
# in through it.
const my $FRONT_DOOR => qr/\A gpforum (?: \s | \z )/msx;

# Sorted keys: the same state prints the same bytes, so two runs diff cleanly
# and a test can compare a document whole.
const my %JSON_SETTINGS => ( canonical => 1, utf8 => 1 );

# The shapes a number an option takes can have, by the name an option table
# gives them. A value outside its shape is misuse.
const my %NUMBER_SHAPE => (
    positive_integer     => qr/\A [1-9][[:digit:]]* \z/msx,
    non_negative_integer => qr/\A [[:digit:]]+ \z/msx,
    non_negative_number  =>
qr/\A (?: [[:digit:]]+ (?: [.] [[:digit:]]+ )? | [.] [[:digit:]]+ ) \z/msx,
);

# Help goes to stdout and succeeds: an operator running `cmd --help | less`
# should not be reading stderr, and a wrapper script should not see a failure.
# What bin/gpforum's adapters answer with. Mojolicious ignores a command's
# return value, so `gpforum search_rebuild --entity bogus` exited 0 where
# bin/gpforum-search-rebuild exits 2: the front door exits with the
# command's status when it is not success.
sub front_door ( $, $status ) {
    if ($status) {
        exit $status;
    }

    return $status;
}

sub help ( $class, $output, $text ) {
    print {$output} _for_terminal( _terminated( $class->as_invoked($text) ) )
      or croak 'failed to write usage';

    return $EXIT_OK;
}

# A usage error goes to stderr and exits 2, distinct from 1 so a caller can
# tell "you invoked me wrongly" from "the work failed". A message that
# already carries the usage -- the parsers throw it with the text -- is
# printed once: admin-bootstrap printed its usage twice, and said nothing
# else.
sub error ( $class, $message, $text ) {
    my $body = q{};
    if ( defined $message && length $message ) {
        $body = ( $class->_explained($message) // $message ) . "\n\n";
    }
    if ( defined $text && length $body && index( $body, $text ) >= 0 ) {
        $text = undef;
        $body =~ s/\s+\z/\n/msx;
    }
    print {*STDERR}
      _for_terminal(
        $class->as_invoked( $body . ( _terminated($text) // q{} ) ) )
      or croak 'failed to write usage error';

    return $EXIT_USAGE;
}

# Misuse is a GPForum::X::Usage, which every option parser throws; anything
# else is a genuine failure and must keep its own exit status. The parsers
# used to croak a text beginning with the usage line and this matched the
# text, which is how scheduled-jobs and outbox-dispatch came to exit 255 on
# misuse: their texts said first what was wrong.
sub is_usage ( $, $error ) {
    return GPForum::X::Usage->caught($error) ? 1 : 0;
}

# Reads a command line against a command's option tables. A switch sets the
# keys it lists; a number option sets its key to the number that follows, which
# must have the option's shape; a value option hands what follows to its own
# sub, which checks and stores it. Anything else is misuse, and the usage
# thrown with it opens with what was wrong: an option the command does not
# have printed the usage alone, and the operator was left to spot the typo.
# Five commands each kept their own copy of this loop and of the number
# checks behind it.
sub parse_options ( $class, $arguments, $options, $table ) {
    my @arguments = @{$arguments};
    while (@arguments) {
        my $argument = shift @arguments;
        if ( exists $table->{switches}{$argument} ) {
            %{$options} = ( %{$options}, %{ $table->{switches}{$argument} } );
        }
        elsif ( exists $table->{numbers}{$argument} ) {
            my ( $name, $shape ) = @{ $table->{numbers}{$argument} };
            $options->{$name} = $class->option_number( shift @arguments,
                $shape, $table->{usage}, $argument );
        }
        elsif ( exists $table->{values}{$argument} ) {
            $table->{values}{$argument}->( $options, shift @arguments );
        }
        else {
            $class->misuse( 'cli.misuse.unknown_option',
                { option => $argument },
                $table->{usage} );
        }
    }

    return $options;
}

# A number an option takes, as a number, when it has the named shape.
sub option_number ( $class, $value, $shape, $usage, $option = undef ) {
    if ( !defined $value || $value !~ $NUMBER_SHAPE{$shape} ) {
        $class->misuse( "cli.misuse.$shape",
            { option => _option_named($option), value => $value // q{} },
            $usage );
    }

    return 0 + $value;
}

# A value an option takes when it is one of those allowed, such as a profile.
sub option_choice ( $class, $value, $allowed, $usage, $option = undef ) {
    if ( !defined $value || !any { $_ eq $value } @{$allowed} ) {
        $class->misuse(
            'cli.misuse.choice',
            {
                choices => join( q{, }, @{$allowed} ),
                option  => _option_named($option),
                value   => $value // q{},
            },
            $usage
        );
    }

    return $value;
}

# A value an option takes when it matches the pattern given, such as a route.
sub option_value ( $class, $value, $pattern, $usage, $option = undef ) {
    if ( !defined $value || $value !~ $pattern ) {
        $class->misuse( 'cli.misuse.value',
            { option => _option_named($option), value => $value // q{} },
            $usage );
    }

    return $value;
}

# Throws the misuse an operator reads: what was wrong, in their language,
# then how the command is used.
sub misuse ( $class, $key, $parameters, $usage ) {
    my $reason =
      GPForum::Command::Support::Words->new->text( $key, $parameters );
    GPForum::X::Usage->throw(
        message => defined $usage ? "$reason\n\n$usage" : $reason );
}

# --json: one JSON object per line on stdout, always with a "status" a script
# can branch on beside the exit code. A command printing several documents (a
# dispatcher looping) prints one line each, so the output reads as JSON Lines.
sub json ( $, $output, $document ) {
    if ( !defined $document->{status} ) {
        GPForum::X::Argument->throw(
            message => 'a --json document carries a status' );
    }

    print {$output} JSON::MaybeXS->new(%JSON_SETTINGS)->encode($document), "\n"
      or croak 'failed to write JSON';

    # Each document reaches its reader when it is printed. Standard output
    # into a pipe is block-buffered, so `outbox-dispatch --loop --json | jq`
    # saw nothing until 8 KB of batches had piled up -- six minutes of idle
    # passes -- and a kill lost them.
    $output->flush or croak 'failed to write JSON';

    return;
}

# The work itself failed. The reason goes to stderr without croak's location,
# and the status is 1, "the work failed": an uncaught exception made Perl exit
# 255, which is no status a caller can branch on. Given a document, --json
# also prints it on stdout with status "fail" and the reason, so a script
# reading stdout finds a status rather than nothing.
#
# The reason can quote a secret: DBI's connect error repeats the DSN, so a
# password= the operator put there came out on stderr and in the document,
# where a log keeps it. It is redacted as the settings page redacts a DSN.
#
# A database the command cannot use -- PostgreSQL down, a wrong password, a
# database or role that does not exist, a schema not migrated -- is said on
# stderr in one sentence that names the setting, the file and the command
# that fixes it (GPForum::Service::Operations::DatabaseFailure); DBIx::Class's own text
# named none of them. A document keeps that text as its error, which scripts
# and archived evidence match, and carries the sentence as its explanation.
#
# A configuration GPForum cannot use is reported as bin/gpforum reports it:
# every problem, in the operator's language (GPForum::Command::Support::Words),
# ending with the environment file this process read, where the error itself
# carries the English; and the status is EX_CONFIG, 78, as bin/gpforum's.
#
# Through the front door, a reason that names a bin/ entrypoint -- "run
# bin/gpforum-partition-maintenance --plan" -- names the verb instead, and a
# gpforum command it offers reads the file this run read: "apply the
# migrations with gpforum migrate", after gpforum --env-file FILE partitions,
# migrated the database the host's file names.
sub failure ( $class, $error, $output = undef, $document = undef ) {
    my $text   = $class->trimmed($error);
    my $reason = GPForum::Service::Admin::Settings->new->redact( $text, [] );
    my $report = _config_report($error);
    my $explained =
      GPForum::Command::Support::ServiceEnvironment->as_read( $report
          // $class->_explained($text) );
    print {*STDERR} _for_terminal(
        GPForum::Command::Support::ServiceEnvironment->as_read(
            $class->as_invoked( $explained // $reason )
        )
      )
      . "\n"
      or croak 'failed to write failure';
    if ( defined $document ) {
        $class->json(
            $output,
            {
                %{$document},
                error => $reason,
                ( defined $explained ? ( explanation => $explained ) : () ),
                status => 'fail',
            }
        );
    }

    return defined $report ? $EXIT_CONFIG : $EXIT_FAILURE;
}

# The sentence for a database failure, or undef for any other error. It is
# read from the text before redaction, and names only the server, the role
# and the database, never a password -- and the environment file the front
# door read, where the setting to correct is.
sub _explained ( $, $text ) {
    my $file = GPForum::Command::Support::ServiceEnvironment->loaded;

    return GPForum::Service::Operations::DatabaseFailure->new(
        defined $file ? ( environment_file => $file ) : () )->sentence($text);
}

# The report of a configuration's problems in the operator's language, without
# its final newline, or undef for any other error. Its last line names the
# environment file this process read, when it read one: the template's name
# sent an operator to a file the service never reads.
sub _config_report ($error) {
    my $invalid = GPForum::X::Config->caught($error);
    return undef if !$invalid || !@{ $invalid->problems };

    return GPForum::Command::Support::Words->new->config_report(
        $invalid->problems,
        GPForum::Command::Support::ServiceEnvironment->loaded ) =~
      s/\s+\z//rmsx;
}

# Text the catalogs wrote is characters and goes out as UTF-8, or an Italian
# "è" reaches the terminal as one stray byte; what a library handed over as
# bytes -- DBI's own error -- goes out as it came.
sub _for_terminal ($text) {
    return utf8::is_utf8($text) ? encode( 'UTF-8', $text ) : $text;
}

# The failure above for an evidence command: one whose check stopped with an
# exception instead of evidence. Under --json -- their default -- the document
# is evidence in its own right: the identity the check's evidence carries (its
# "check", or stress-load's "mode"), status "fail", the reason, and the
# markers evidence-validate --strict asks an archived file for, so a failed
# run can be archived beside the passing ones. The evidence commands rethrew
# such an error with die, which exits 255 or with whatever $! held -- 2,
# misuse, after a failed file lookup.
sub evidence_failure ( $class, $error, $format, $identity ) {
    return $class->failure($error) if ( $format // q{} ) ne 'json';

    return $class->failure( $error, \*STDOUT, evidence_finalize($identity) );
}

sub wants_help ( $, @arguments ) {
    return scalar grep { $_ eq '--help' || $_ eq '-h' } @arguments;
}

# croak appends " at FILE line N.", which is debugging information for a
# programmer and noise for an operator reading how to use a program. Fifty-nine
# croak _usage() sites leaked it into help text. A rethrown error carries one
# per throw -- a DBIx::Class connection failure ends "at DBI.pm line 1639. at
# Migrate.pm line 9" -- so every trailing one goes.
sub trimmed ( $, $error ) {
    my $text = defined $error ? "$error" : q{};
    while (
        $text =~ s/\s+ at \s+ \S+ \s+ line \s+ [[:digit:]]+ [.]? \s*\z//msx )
    {
    }
    $text =~ s/\s+\z//msx;

    return $text;
}

# The name the operator actually invoked. Five usage texts hardcoded a
# script/ path, so running bin/gpforum-bench-hypnotoad --help answered with
# "Usage: script/bench-hypnotoad". Both entrypoints exist -- script/ is a shell
# wrapper that execs the bin/ one -- so $0 is the truthful, runnable name
# whichever was typed.
#
# The invocant is named rather than written as a lone `$`: a one-element
# signature holding only a sigil is the one shape Perl itself cannot
# distinguish from a prototype, which is why architecture-check refuses it.
sub program ($class) {
    return $PROGRAM_NAME;
}

# A text as the operator invoked the program: through the front door, each
# bin/ entrypoint it names is written as the verb that runs it.
sub as_invoked ( $class, $text ) {
    return $text if $class->program !~ $FRONT_DOOR;

    return GPForum::Command::Support::Verbs->as_typed($text);
}

sub _option_named ($option) {
    return $option
      // GPForum::Command::Support::Words->new->text('cli.misuse.the_value');
}

sub _terminated ($text) {
    return $text if !defined $text;
    return $text if $text =~ /\n\z/msx;

    return "$text\n";
}

1;

__END__

=head1 NAME

GPForum::Command::Usage - Shared help, usage errors and exit codes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    return GPForum::Command::Usage->help( $self->output, _usage() )
      if $options->{help};

    return GPForum::Command::Usage->error( "unknown option $name", _usage() );

    GPForum::Command::Usage->json( \*STDOUT, { status => 'ok', ... } );

=head1 DESCRIPTION

Gives every entrypoint the same operator-facing behaviour: C<--help> prints to
standard output and exits 0, a usage error says what was wrong and prints the
usage to standard error and exits 2, and neither leaks the C<at FILE line N>
suffix that C<croak> appends. A failure of the work itself exits 1 with its
reason on standard error -- 78, EX_CONFIG, when it is settings the command
cannot use -- and a command's C<--json> mode prints one JSON object per line,
each with a C<status>; F<docs/ops/console-and-cli.md> lists the shapes.
Through the front door (C<gpforum VERB>), a text that names a C<bin/>
entrypoint names its verb instead.

=head1 SUBROUTINES/METHODS

=head2 front_door

Exits with a command's status when it is not success; returns it otherwise.

=head2 help

Prints the usage text, as invoked, to the given handle and returns
C<$EXIT_OK>.

=head2 is_usage

True when an error is a L<GPForum::X::Usage> -- the command was called the
wrong way -- rather than a failure of its work.

=head2 json

Prints a document as one line of JSON with sorted keys, and flushes the
handle so a reader sees it at once. Throws L<GPForum::X::Argument> when the
document has no C<status>.

=head2 failure

Prints a failure's reason to standard error and, given a document, the
document with C<status> C<fail> and the C<error> as JSON; returns
C<$EXIT_FAILURE>, or C<$EXIT_CONFIG> (78) for settings with problems. An inline password in the reason, such as a DSN's
C<password=>, is redacted in both. A database the command could not use is
said on standard error in the one sentence
L<GPForum::Service::Operations::DatabaseFailure> writes, in the operator's language; the
document keeps the original text as its C<error> and adds the sentence as
C<explanation>; a C<gpforum> command either offers names the environment
file this process read with C<--env-file>, when that is not the host's
(L<GPForum::Command::Support::ServiceEnvironment/as_read>). A configuration
with problems (a L<GPForum::X::Config> that
carries them) is reported whole on standard error in the operator's
language, as C<bin/gpforum> reports it, its last line naming the
environment file this process read
(L<GPForum::Command::Support::ServiceEnvironment>), and is the document's
C<explanation>.

=head2 evidence_failure

The L</failure> of an evidence command, given the error, the output format
and the identity its evidence carries (C<< { check => 'staging_drill' } >>).
With the C<json> format it prints, on standard output, that identity
finalized as evidence by L<GPForum::Service::Operations::EvidenceMeta> --
C<secrets_redacted>, C<private_beta_claimed>, C<residual_gaps> -- with
C<status> C<fail> and the redacted C<error>; with any other, only the reason
on standard error. Returns C<$EXIT_FAILURE>.

=head2 wants_help

True when the argument list asks for help.

=head2 trimmed

Strips croak's C<at FILE line N> suffix from an error.

=head2 program

Returns the name this program was invoked as.

=head2 parse_options

Reads an argument list into a hash of options against a table:
C<switches> maps an option to the keys and values it sets, C<numbers> maps an
option to C<[ key, shape ]> where the shape is C<positive_integer>,
C<non_negative_integer> or C<non_negative_number>, and C<values> maps an
option to a sub given the options and the value that follows. Anything else
throws a L<GPForum::X::Usage> whose text says which option it does not know,
then gives the table's C<usage> text. Returns the options.

=head2 misuse

Takes a key of L<GPForum::Command::Support::Words>, its placeholder values
and a usage text, and throws a L<GPForum::X::Usage> that says what was wrong,
in the operator's language, then gives the usage.

=head2 option_number

Returns an option's value as a number when it has the named shape; throws
L</misuse> otherwise, naming the option when it is given as a fourth
argument.

=head2 option_choice

Returns an option's value when it is one of the allowed values; throws
L</misuse> otherwise, listing them.

=head2 option_value

Returns an option's value when it matches the pattern; throws L</misuse>
otherwise.

=head2 as_invoked

A text as the operator invoked the program: through the front door, each
C<bin/gpforum-NAME> it names written as the verb
(L<GPForum::Command::Support::Verbs/as_typed>); otherwise unchanged.

=head2 error

Prints an optional message and the usage text to standard error, and returns
C<$EXIT_USAGE>. A message that is a database failure is said as L</failure>
says it; one that already carries the usage text is printed once.

=head1 DIAGNOSTICS

Croaks only when the output handle cannot be written. The option readers
throw L<GPForum::X::Usage>, which L</is_usage> recognises.

=head1 CONFIGURATION AND ENVIRONMENT

Reads none itself; L<GPForum::Service::Operations::DatabaseFailure> reads C<LC_ALL>,
C<LC_MESSAGES>, C<LANG> and C<GPFORUM_ENV> to choose the language and the
file a database failure names, and L<GPForum::Command::Support::Words> the
first three for a configuration's report and the misuse it says.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<JSON::MaybeXS>, L<List::Util>, L<Mojo::Base>, for
database failures L<GPForum::Service::Operations::DatabaseFailure>, for a
configuration's report and for misuse L<GPForum::Command::Support::Words>,
L<GPForum::Command::Support::ServiceEnvironment>, L<Mojo::Util> and
L<GPForum::X::Config>, for the front door's names
L<GPForum::Command::Support::Verbs>, for its redaction
L<GPForum::Service::Admin::Settings>, for an evidence command's failure
L<GPForum::Service::Operations::EvidenceMeta>, and to recognise misuse
L<GPForum::X::Usage>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The exit codes are a convention this module names; it cannot enforce that a
command returns what it is given.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
