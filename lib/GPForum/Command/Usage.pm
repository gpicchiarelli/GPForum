# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::Usage;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use IO::Handle    ();
use JSON::MaybeXS ();
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Service::Admin::Settings;
use GPForum::Service::Operations::EvidenceMeta qw(evidence_finalize);

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

# Sorted keys: the same state prints the same bytes, so two runs diff cleanly
# and a test can compare a document whole.
const my %JSON_SETTINGS => ( canonical => 1, utf8 => 1 );

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

sub help ( $, $output, $text ) {
    print {$output} _terminated($text)
      or croak 'failed to write usage';

    return $EXIT_OK;
}

# A usage error goes to stderr and exits 2, distinct from 1 so a caller can
# tell "you invoked me wrongly" from "the work failed".
sub error ( $, $message, $text ) {
    my $body = q{};
    if ( defined $message && length $message ) {
        $body = "$message\n\n";
    }
    print {*STDERR} $body . _terminated($text)
      or croak 'failed to write usage error';

    return $EXIT_USAGE;
}

# The name the operator actually invoked. Five usage texts hardcoded a
# script/ path, so running bin/gpforum-bench-hypnotoad --help answered with
# "Usage: script/bench-hypnotoad". Both entrypoints exist -- script/ is a shell
# wrapper that execs the bin/ one -- so $0 is the truthful, runnable name
# whichever was typed.
# A croak that begins with the usage line is misuse; anything else is a
# genuine failure and must keep its own exit status. The usage may follow one
# line saying what was wrong ("unknown option --bad"), the way most parsers
# here croak: recognising only a text that starts with the usage line is how
# scheduled-jobs and outbox-dispatch came to exit 255 on misuse.
sub is_usage ( $, $text ) {
    return 0 if !defined $text;

    return $text =~ /\A (?: [^\n]* \n )? Usage: /msx ? 1 : 0;
}

# --json: one JSON object per line on stdout, always with a "status" a script
# can branch on beside the exit code. A command printing several documents (a
# dispatcher looping) prints one line each, so the output reads as JSON Lines.
sub json ( $, $output, $document ) {
    croak 'a --json document carries a status'
      if !defined $document->{status};

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
sub failure ( $class, $error, $output = undef, $document = undef ) {
    my $text   = $class->trimmed($error);
    my $reason = GPForum::Service::Admin::Settings->new->redact( $text, [] );
    print {*STDERR} "$reason\n" or croak 'failed to write failure';
    if ( defined $document ) {
        $class->json( $output,
            { %{$document}, error => $reason, status => 'fail' } );
    }

    return $EXIT_FAILURE;
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

# The invocant is named rather than written as a lone `$`: a one-element
# signature holding only a sigil is the one shape Perl itself cannot
# distinguish from a prototype, which is why architecture-check refuses it.
sub program ($class) {
    return $PROGRAM_NAME;
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
standard output and exits 0, a usage error prints to standard error and exits
2, and neither leaks the C<at FILE line N> suffix that C<croak> appends. A
failure of the work itself exits 1 with its reason on standard error, and a
command's C<--json> mode prints one JSON object per line, each with a
C<status>; F<docs/ops/console-and-cli.md> lists the shapes.

=head1 SUBROUTINES/METHODS

=head2 front_door

Exits with a command's status when it is not success; returns it otherwise.

=head2 help

Prints the usage text to the given handle and returns C<$EXIT_OK>.

=head2 is_usage

True when an error text is a usage message rather than a failure: the usage
line comes first, or second after one line saying what was wrong.

=head2 json

Prints a document as one line of JSON with sorted keys, and flushes the
handle so a reader sees it at once. Croaks when the document has no
C<status>.

=head2 failure

Prints a failure's reason to standard error and, given a document, the
document with C<status> C<fail> and the C<error> as JSON; returns
C<$EXIT_FAILURE>. An inline password in the reason, such as a DSN's
C<password=>, is redacted in both.

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

=head2 error

Prints an optional message and the usage text to standard error, and returns
C<$EXIT_USAGE>.

=head1 DIAGNOSTICS

Croaks only when the output handle cannot be written.

=head1 CONFIGURATION AND ENVIRONMENT

No environment variables are read.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<JSON::MaybeXS>, L<Mojo::Base>, for its redaction
L<GPForum::Service::Admin::Settings>, and for an evidence command's failure
L<GPForum::Service::Operations::EvidenceMeta>.

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
