# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::Usage;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

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
# genuine failure and must keep its own exit status.
sub is_usage ( $, $text ) {
    return 0 if !defined $text;

    return $text =~ /\A Usage: /msx ? 1 : 0;
}

sub wants_help ( $, @arguments ) {
    return scalar grep { $_ eq '--help' || $_ eq '-h' } @arguments;
}

# croak appends " at FILE line N.", which is debugging information for a
# programmer and noise for an operator reading how to use a program. Fifty-nine
# croak _usage() sites leaked it into help text.
sub trimmed ( $, $error ) {
    my $text = defined $error ? "$error" : q{};
    $text =~ s/\s+ at \s+ \S+ \s+ line \s+ [[:digit:]]+ [.]? \s*\z//msx;
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

=head1 DESCRIPTION

Gives every entrypoint the same operator-facing behaviour: C<--help> prints to
standard output and exits 0, a usage error prints to standard error and exits
2, and neither leaks the C<at FILE line N> suffix that C<croak> appends.

=head1 SUBROUTINES/METHODS

=head2 front_door

Exits with a command's status when it is not success; returns it otherwise.

=head2 help

Prints the usage text to the given handle and returns C<$EXIT_OK>.

=head2 is_usage

True when an error text is a usage message rather than a failure.

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

Uses L<Const::Fast> and L<Mojo::Base>.

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
