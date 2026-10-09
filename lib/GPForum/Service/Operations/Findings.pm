# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::Findings;

use Const::Fast;
use List::Util qw(any);
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Service::I18N::CliCatalog;
use GPForum::X::Argument;

our $VERSION = '0.001';

# What an operator reads from a check of the host: one line per finding,
# marked as the walkthrough's target experience marks it (audit 5.2), and
# under a problem the commands that fix it. A finding that did not apply is
# kept for --json and left out of the lines: the operator reads what is
# there, not what was not looked at.
const my %MARK => (
    ok       => "\N{CHECK MARK}",
    degraded => q{!},
    fail     => "\N{BALLOT X}",
);
const my %RANK => (
    skipped  => 0,
    ok       => 0,
    degraded => 1,
    fail     => 2,
);
const my $NOTE_INDENT => q{ } x 4;

has catalog => sub { return GPForum::Service::I18N::CliCatalog->new; };
has items   => sub { return [] };

# A finding: its name, for scripts; its status (ok, degraded, fail or
# skipped); its message; notes that say what it proved or did not; and the
# fixes, each a line an operator can type or follow. A message, a note or a
# fix is either text already in the operator's language or a key of the
# command-line catalogs with its values: [ key, { name => value } ].
sub add ( $self, %finding ) {
    if ( !exists $RANK{ $finding{status} // q{} } ) {
        GPForum::X::Argument->throw(
            message => 'a finding is ok, degraded, fail or skipped' );
    }

    push @{ $self->items },
      {
        name    => $finding{name},
        status  => $finding{status},
        message => $finding{message},
        notes   => $finding{notes} // [],
        fixes   => $finding{fixes} // [],
      };

    return $self;
}

# Every finding of another list, after this one's.
sub merge ( $self, $other ) {
    push @{ $self->items }, @{ $other->items };

    return $self;
}

# The worst status among the findings: fail, degraded, or ok.
sub status ($self) {
    my $worst = 'ok';
    for my $item ( @{ $self->items } ) {
        if ( $RANK{ $item->{status} } > $RANK{$worst} ) {
            $worst = $item->{status};
        }
    }

    return $worst;
}

# 1 when a finding failed: the forum cannot work as configured. A degraded
# one is reported and counted, and the command still succeeds.
sub exit_status ($self) {
    return ( any { $_->{status} eq 'fail' } @{ $self->items } ) ? 1 : 0;
}

# The findings an operator has to act on.
sub problems ($self) {
    return [ grep { $RANK{ $_->{status} } > 0 } @{ $self->items } ];
}

# The lines an operator reads, ending in a newline, with a closing line that
# counts what there is to fix unless told not to.
sub human_text ( $self, %options ) {
    my @lines = map { $self->_lines($_) }
      grep { $_->{status} ne 'skipped' } @{ $self->items };
    if ( $options{summary} // 1 ) {
        push @lines, q{}, $self->summary;
    }

    return join( "\n", @lines ) . "\n";
}

# Only the problems, each line behind a prefix, as a journal shows them.
sub problem_lines ( $self, $prefix ) {
    return [
        map { "$prefix$_" }
        map { $self->_lines($_) } @{ $self->problems }
    ];
}

sub summary ($self) {
    my $count = scalar @{ $self->problems };
    return $self->_say( ['findings.summary_none'] ) if !$count;
    return $self->_say( ['findings.summary_one'] )  if $count == 1;

    return $self->_say( [ 'findings.summary_many', { count => $count } ] );
}

# The findings as --json carries them: each one's name and status, its
# message, notes and fixes as the operator reads them, and the key and
# values of a message the catalogs hold, for a script that wants neither
# language.
sub document ($self) {
    return [ map { $self->_document_item($_) } @{ $self->items } ];
}

# A message, note or fix in the operator's language.
sub text_of ( $self, $message ) {
    return $self->_say($message);
}

sub _document_item ( $self, $item ) {
    my $message = $item->{message};

    return {
        name    => $item->{name},
        status  => $item->{status},
        message => $self->_say($message),
        notes   => [ map { $self->_say($_) } @{ $item->{notes} } ],
        fixes   => [ map { $self->_say($_) } @{ $item->{fixes} } ],
        (
            ref $message eq 'ARRAY'
            ? ( key => $message->[0], parameters => $message->[1] // {} )
            : ()
        ),
    };
}

sub _lines ( $self, $item ) {
    my @lines =
      ( $MARK{ $item->{status} } . q{ } . $self->_say( $item->{message} ) );
    push @lines, map { $NOTE_INDENT . $self->_say($_) } @{ $item->{notes} };

    # Each fix after the first stands under the first one's text, past the
    # "Fix: " the operator's language puts before it.
    my @fixes = map { $self->_say($_) } @{ $item->{fixes} };
    if (@fixes) {
        my $first  = shift @fixes;
        my $prefix = $self->_say( [ 'findings.fix', { fix => q{} } ] );
        push @lines,
          $NOTE_INDENT . $self->_say( [ 'findings.fix', { fix => $first } ] ),
          map { $NOTE_INDENT . ( q{ } x length $prefix ) . $_ } @fixes;
    }

    return @lines;
}

sub _say ( $self, $message ) {
    return q{}      if !defined $message;
    return $message if ref $message ne 'ARRAY';

    my ( $key, $parameters ) = @{$message};
    return $self->catalog->text( $key, $parameters // {} );
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::Findings - What a check of the host found, as
an operator reads it.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $findings = GPForum::Service::Operations::Findings->new;
    $findings->add(
        name    => 'antivirus',
        status  => 'degraded',
        message => [ 'doctor.antivirus_unreachable', { socket => $socket } ],
        fixes   => [ 'sudo apt install clamav-daemon clamav-freshclam' ],
    );
    print $findings->human_text;
    exit $findings->exit_status;

=head1 DESCRIPTION

Collects findings and writes them the way C<gpforum doctor>, C<gpforum
status> and the host checks write them: a check mark for what is fine, C<!>
for what works but should be fixed, a cross for what stops the forum working
as configured, and under a problem a C<Fix:> line for each thing to type or
change. The words come from the command-line catalogs in C<locale/cli/>, in
the operator's language (L<GPForum::Service::I18N::CliCatalog>).

=head1 SUBROUTINES/METHODS

=head2 catalog

The L<GPForum::Service::I18N::CliCatalog> the words come from; the
operator's language by default.

=head2 items

The findings, in the order they were added.

=head2 add

Takes C<name>, C<status> (C<ok>, C<degraded>, C<fail> or C<skipped>),
C<message>, and optional C<notes> and C<fixes> array references. A message,
note or fix is a text, or C<[ key, { name => value } ]> for the catalogs.
Returns the list. Throws L<GPForum::X::Argument> for any other status.

=head2 merge

Adds every finding of another list, and returns this one.

=head2 status

C<fail> when any finding failed, else C<degraded> when any is degraded, else
C<ok>.

=head2 exit_status

1 when any finding failed, else 0.

=head2 problems

The degraded and failed findings.

=head2 human_text

The lines an operator reads, skipped findings left out, ending in a newline.
A closing line counts the problems unless C<< summary => 0 >> is given.

=head2 problem_lines

Takes a prefix and returns the lines of the problems only, each behind it,
for a journal.

=head2 summary

The closing line: nothing to fix, one thing, or how many.

=head2 document

The findings for C<--json>: an array of C<name>, C<status>, C<message>,
C<notes> and C<fixes> as the operator reads them, and for a message from
the catalogs its C<key> and C<parameters>.

=head2 text_of

A message, note or fix in the catalog's language.

=head1 DIAGNOSTICS

L</add> throws L<GPForum::X::Argument> for a status it does not know.

=head1 CONFIGURATION AND ENVIRONMENT

The language follows C<LC_ALL>, C<LC_MESSAGES> and C<LANG> unless a catalog
is given.

=head1 DEPENDENCIES

L<Const::Fast>, L<List::Util>, L<Mojo::Base>,
L<GPForum::Service::I18N::CliCatalog>, L<GPForum::X::Argument>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The marks are Unicode; a terminal that cannot show them shows what it
shows for any other UTF-8.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
