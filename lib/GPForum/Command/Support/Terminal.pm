# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::Support::Terminal;

use Carp qw(croak);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::Util qw(decode encode);
use POSIX      ();

our $VERSION = '0.001';

# How a command asks the operator something at the terminal: gpforum admin
# create its password, gpforum setup its three questions and an SMTP
# password. The question goes to standard error, so standard output stays
# the command's answer.

# Where the answer is read from and the question written to; a test gives
# its own.
has input  => sub { return \*STDIN; };
has prompt => sub { return \*STDERR; };

# Whether there is a terminal to ask on: a pipe or a file is not one.
sub is_interactive ($self) {
    return POSIX::isatty( fileno $self->input ) ? 1 : 0;
}

# One line, as typed, without its newline; undef at the end of the input
# (Ctrl-D).
sub line ( $self, $question ) {
    $self->_ask($question);
    my $input  = $self->input;
    my $answer = _chomped( scalar <$input> );

    return defined $answer ? decode( 'UTF-8', $answer ) // $answer : undef;
}

# One line with the terminal's echo off, and back on whatever happens, an
# interrupt included; for a password, which is kept as the bytes typed.
sub hidden_line ( $self, $question ) {
    my $input    = $self->input;
    my $terminal = POSIX::Termios->new;
    my $fileno   = fileno $input;
    $terminal->getattr($fileno);
    my $echoing = $terminal->getlflag;

    $self->_ask($question);
    $terminal->setlflag( $echoing & ~POSIX::ECHO() );
    $terminal->setattr( $fileno, POSIX::TCSANOW() );
    my $answer;
    {
        local $SIG{INT} = sub {
            $terminal->setlflag($echoing);
            $terminal->setattr( $fileno, POSIX::TCSANOW() );
            exit 1;
        };
        $answer = <$input>;
    }
    $terminal->setlflag($echoing);
    $terminal->setattr( $fileno, POSIX::TCSANOW() );
    print { $self->prompt } "\n" or croak 'failed to write the prompt';

    return _chomped($answer);
}

sub _ask ( $self, $question ) {
    print { $self->prompt } encode( 'UTF-8', "$question " )
      or croak 'failed to write the prompt';

    return;
}

sub _chomped ($answer) {
    return undef if !defined $answer;
    chomp $answer;

    return $answer;
}

1;

__END__

=head1 NAME

GPForum::Command::Support::Terminal - Asks the operator at the terminal.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $terminal = GPForum::Command::Support::Terminal->new;
    if ( $terminal->is_interactive ) {
        my $password = $terminal->hidden_line('Password:');
    }

=head1 DESCRIPTION

The questions a command asks: written to standard error, answered on
standard input, a password with the echo off.

=head1 SUBROUTINES/METHODS

=head2 is_interactive

Whether the input is a terminal.

=head2 line

Asks a question and returns the line typed, without its newline, or undef
at the end of the input.

=head2 hidden_line

The same with the terminal's echo off, restored even on an interrupt; the
answer is the bytes typed, as a password is hashed.

=head1 DIAGNOSTICS

Croaks when the question cannot be written.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<POSIX> for the terminal's echo.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

C<hidden_line> needs a terminal POSIX termios can turn the echo off on.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
