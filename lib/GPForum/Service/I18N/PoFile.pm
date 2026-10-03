# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::I18N::PoFile;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File qw(path);
use Mojo::Util qw(decode);

our $VERSION = '0.001';

# The escapes gettext writes in a PO string. Anything else after a backslash
# is refused rather than guessed at.
const my %ESCAPES => (
    q{\\} => q{\\},
    q{"}  => q{"},
    n     => "\n",
    r     => "\r",
    t     => "\t",
);

# Each keyword that opens a line of an entry, and the reader that takes it.
const my %KEYWORDS => (
    msgctxt      => \&_take_context,
    msgid        => \&_take_id,
    msgid_plural => \&_take_plural_id,
    msgstr       => \&_take_translation,
);

const my $KEYWORD      => qr/msgctxt|msgid_plural|msgid|msgstr/msx;
const my $INDEX        => qr/[[]([[:digit:]]+)[]]/msx;
const my $KEYWORD_LINE => qr/\A ($KEYWORD) (?:$INDEX)? \s+ (.*) \z/msx;
const my $STRING_LINE  => qr/\A \s* (".*) \z/msx;
const my $QUOTED       => qr/\A " ((?: [^"\\] | [\\]. )*) " \s* \z/msx;

sub read_file ( $class, $file ) {
    my $text = decode( 'UTF-8', path($file)->slurp );
    croak "$file is not valid UTF-8" if !defined $text;

    return $class->parse( $text, $file );
}

sub parse ( $, $text, $name ) {
    my $reader = {
        name    => $name,
        entries => [],
        entry   => _blank_entry(),
        target  => undef,
        seen    => {},
        header  => undef,
    };
    $text =~ s/\A \N{BYTE ORDER MARK}//msx;

    my $number = 0;
    for my $line ( split /\r?\n/msx, $text ) {
        $number++;
        _take_line( $reader, $line, $number );
    }
    _close_entry($reader);

    return _document($reader);
}

sub _blank_entry {
    return {
        context   => undef,
        id        => undef,
        id_plural => undef,
        strings   => [],
        flags     => {},
        comments  => [],
        line      => undef,
    };
}

# Blank lines carry nothing in a PO file: an entry ends where the next one's
# comments or msgctxt/msgid begin, as gettext reads it.
sub _take_line ( $reader, $line, $number ) {
    if ( $line =~ /\A \s* \z/msx ) {
        return;
    }
    if ( $line =~ /\A [#]/msx ) {
        return _take_comment( $reader, $line, $number );
    }
    if ( my ( $keyword, $index, $literal ) = $line =~ $KEYWORD_LINE ) {
        croak _at( $reader, $number ), ": $keyword takes no [$index]"
          if defined $index && $keyword ne 'msgstr';

        return $KEYWORDS{$keyword}->(
            $reader,
            {
                index => $index,
                line  => $number,
                text  => _string( $reader, $literal, $number ),
            }
        );
    }
    if ( my ($continued) = $line =~ $STRING_LINE ) {
        return _continue( $reader, _string( $reader, $continued, $number ),
            $number );
    }

    croak _at( $reader, $number ), ': not a comment, a keyword or a string';
}

sub _take_comment ( $reader, $line, $number ) {
    if ( @{ $reader->{entry}{strings} } ) {
        _close_entry($reader);
    }
    croak _at( $reader, $number ),
      ': a comment inside an entry, before its msgstr'
      if _started( $reader->{entry} );

    my $entry = $reader->{entry};
    $reader->{target} = undef;

    # An obsolete entry (#~), which msgmerge keeps and nothing reads. The
    # comments and flags above it are its own, not the next entry's.
    if ( $line =~ /\A [#] ~/msx ) {
        $entry->{flags}    = {};
        $entry->{comments} = [];
        return;
    }
    if ( my ($flags) = $line =~ /\A [#] , (.*) \z/msx ) {
        for my $flag ( grep { length } map { _trim($_) } split /,/msx, $flags )
        {
            $entry->{flags}{$flag} = 1;
        }
        return;
    }

    # A translator's comment is "#" alone or "# " and text; "#." (extracted),
    # "#:" (reference) and "#|" (previous msgid) are the tools' and skipped.
    if ( my ($comment) = $line =~ /\A [#] (?:[ ] (.*))? \z/msx ) {
        push @{ $entry->{comments} }, $comment // q{};
    }

    return;
}

sub _take_context ( $reader, $token ) {
    my $entry = _open_entry($reader);
    croak _at( $reader, $token->{line} ), ': msgctxt must open its entry'
      if _started($entry);

    $entry->{line}    = $token->{line};
    $entry->{context} = $token->{text};
    $reader->{target} = \$entry->{context};

    return;
}

sub _take_id ( $reader, $token ) {
    my $entry = _open_entry($reader);
    croak _at( $reader, $token->{line} ), ': a second msgid before a msgstr'
      if defined $entry->{id};

    $entry->{line} //= $token->{line};
    $entry->{id}      = $token->{text};
    $reader->{target} = \$entry->{id};

    return;
}

sub _take_plural_id ( $reader, $token ) {
    my $entry = $reader->{entry};
    croak _at( $reader, $token->{line} ),
      ': msgid_plural must follow its msgid, before any msgstr'
      if !defined $entry->{id}
      || defined $entry->{id_plural}
      || @{ $entry->{strings} };

    $entry->{id_plural} = $token->{text};
    $reader->{target}   = \$entry->{id_plural};

    return;
}

sub _take_translation ( $reader, $token ) {
    my $entry   = $reader->{entry};
    my $problem = _misplaced_translation( $entry, $token->{index} );
    croak _at( $reader, $token->{line} ), ": $problem" if length $problem;

    push @{ $entry->{strings} }, $token->{text};
    $reader->{target} = \$entry->{strings}[-1];

    return;
}

# msgstr follows msgid. A plural entry (one with msgid_plural) numbers its
# forms msgstr[0], msgstr[1], ... in order; any other entry has one msgstr.
sub _misplaced_translation ( $entry, $index ) {
    if ( !defined $entry->{id} ) {
        return 'msgstr before msgid';
    }
    if ( !defined $entry->{id_plural} ) {
        if ( defined $index ) {
            return "msgstr[$index] in an entry without msgid_plural";
        }
        return @{ $entry->{strings} } ? 'a second msgstr' : q{};
    }
    if ( !defined $index ) {
        return 'a plural entry numbers its forms: msgstr[0], msgstr[1]';
    }

    my $expected = scalar @{ $entry->{strings} };
    return $index == $expected
      ? q{}
      : "msgstr[$index] where msgstr[$expected] belongs";
}

sub _continue ( $reader, $text, $number ) {
    my $target = $reader->{target};
    croak _at( $reader, $number ), ': a string with no keyword before it'
      if !$target;

    ${$target} .= $text;

    return;
}

sub _open_entry ($reader) {
    if ( @{ $reader->{entry}{strings} } ) {
        _close_entry($reader);
    }

    return $reader->{entry};
}

sub _close_entry ($reader) {
    my $entry = $reader->{entry};
    $reader->{entry}  = _blank_entry();
    $reader->{target} = undef;

    # Comments with no entry after them, at the end of the file.
    if ( !_started($entry) ) {
        return;
    }
    croak _at( $reader, $entry->{line} ),
      ': an entry needs a msgid and a msgstr'
      if !defined $entry->{id} || !@{ $entry->{strings} };

    return _record( $reader, $entry );
}

# A message is its msgctxt and msgid together, as for msgfmt: the same pair
# twice is refused, with the line of the first.
sub _record ( $reader, $entry ) {
    my $context =
      defined $entry->{context} ? "msgctxt $entry->{context}" : 'no msgctxt';
    my $first = $reader->{seen}{$context}{ $entry->{id} };
    croak _at( $reader, $entry->{line} ), ": the same message as line $first"
      if defined $first;
    $reader->{seen}{$context}{ $entry->{id} } = $entry->{line};

    if ( !defined $entry->{context} && $entry->{id} eq q{} ) {
        croak _at( $reader, $entry->{line} ),
          ': the header (msgid "") must be the first entry'
          if @{ $reader->{entries} };
        $reader->{header} = $entry;
        return;
    }

    push @{ $reader->{entries} }, $entry;

    return;
}

sub _document ($reader) {
    my $header = $reader->{header};
    croak "$reader->{name}: no header entry (msgid \"\") opens the file"
      if !$header;

    my $fields = _header_fields( $reader, $header );
    _check_charset( $reader, $fields );
    _check_plural_counts( $reader, $fields );

    return {
        header  => $fields,
        entries => $reader->{entries},
    };
}

sub _header_fields ( $reader, $header ) {
    my %fields;
    for my $line ( grep { length } split /\n/msx, $header->{strings}[0] ) {
        my ( $field, $value ) = $line =~ /\A ([^:]+) : \s* (.*) \z/msx;
        croak _at( $reader, $header->{line} ),
          ": header line '$line' is not 'Field: value'"
          if !defined $field;
        $fields{$field} = $value;
    }

    return \%fields;
}

sub _check_charset ( $reader, $fields ) {
    my ($charset) =
      ( $fields->{'Content-Type'} // q{} ) =~ /charset = ([^\s;]+)/imsx;
    croak "$reader->{name}: the header must declare charset=UTF-8"
      if !defined $charset || lc $charset ne 'utf-8';

    return;
}

sub _check_plural_counts ( $reader, $fields ) {
    my ($forms) = ( $fields->{'Plural-Forms'} // q{} ) =~
      /nplurals \s* = \s* ([[:digit:]]+)/msx;
    for my $entry ( grep { defined $_->{id_plural} } @{ $reader->{entries} } ) {
        croak _at( $reader, $entry->{line} ),
          ': a plural entry, but the header has no Plural-Forms'
          if !defined $forms;
        my $count = scalar @{ $entry->{strings} };
        croak _at( $reader, $entry->{line} ),
          ": $count plural forms where Plural-Forms declares $forms"
          if $count != $forms;
    }

    return;
}

sub _string ( $reader, $literal, $number ) {
    my ($body) = $literal =~ $QUOTED;
    croak _at( $reader, $number ), ': not one "quoted" string'
      if !defined $body;

    my $text = q{};
    for my $part ( split /([\\].)/msx, $body ) {
        if ( index( $part, q{\\} ) != 0 ) {
            $text .= $part;
            next;
        }
        my $escape = substr $part, 1;
        croak _at( $reader, $number ), ": unknown escape $part"
          if !exists $ESCAPES{$escape};
        $text .= $ESCAPES{$escape};
    }

    return $text;
}

sub _started ($entry) {
    return defined $entry->{context} || defined $entry->{id} ? 1 : 0;
}

sub _trim ($value) {
    $value =~ s/\A \s+ | \s+ \z//gmsx;

    return $value;
}

sub _at ( $reader, $number ) {
    return "$reader->{name} line $number";
}

1;

__END__

=head1 NAME

GPForum::Service::I18N::PoFile - A reader for the gettext PO files that hold the catalogs.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $document =
      GPForum::Service::I18N::PoFile->read_file('locale/it.po');

    my $language = $document->{header}{Language};    # it
    for my $entry ( @{ $document->{entries} } ) {
        my ( $key, $text ) = ( $entry->{context}, $entry->{strings}[0] );
    }

=head1 DESCRIPTION

Reads a GNU gettext PO file, the format translators' tools edit, into its
header and entries, and refuses one it cannot read exactly. It reads what
the catalogs in C<locale/> use and what C<msgmerge>, C<msginit> and Poedit
write: C<msgctxt>, C<msgid>, C<msgid_plural>, C<msgstr> and C<msgstr[N]>,
strings continued over several lines, the escapes C<\\>, C<\">, C<\n>,
C<\r> and C<\t>, translator comments and flags. Extracted, reference and
previous-msgid comments are skipped, and obsolete C<#~> entries are left out
with their comments and flags.

It reads the format and nothing more: which entries count as translated,
and what a key or a plural form means, is
L<GPForum::Service::I18N::Catalog>'s business.

=head1 SUBROUTINES/METHODS

=head2 read_file

Takes a path. Reads the file as UTF-8 and returns what L</parse> returns for
it, with the path naming the file in any error.

=head2 parse

Takes the text of a PO file (characters, not bytes) and a name for it in
errors. Returns a hash reference: C<header>, the header entry's fields
(C<< { Language => 'it', 'Plural-Forms' => '...', ... } >>), and
C<entries>, an array reference of the other entries in file order, each a
hash reference of C<context> (msgctxt, or undef), C<id>, C<id_plural>
(undef unless plural), C<strings> (the msgstr, or every msgstr[N] in
order), C<flags> (a hash reference, such as C<< { fuzzy => 1 } >>),
C<comments> (the translator's comment lines) and C<line>, where the entry
begins.

=head1 DIAGNOSTICS

Each problem croaks with the file's name and, where there is one, the line:

=over 4

=item C<FILE is not valid UTF-8>

=item C<FILE line N: not a comment, a keyword or a string>, or C<a string
with no keyword before it>

=item C<FILE line N: not one "quoted" string>, or C<unknown escape \q>

=item C<FILE line N: KEYWORD takes no [I]>

Only C<msgstr> is numbered, as C<msgstr[0]>.

=item C<FILE line N: msgctxt must open its entry>, C<a second msgid before a
msgstr>, C<msgid_plural must follow its msgid, before any msgstr>,
C<msgstr before msgid>, C<a second msgstr>, C<msgstr[N] in an entry without
msgid_plural>, C<a plural entry numbers its forms: msgstr[0], msgstr[1]>,
C<msgstr[N] where msgstr[M] belongs>, or C<a comment inside an entry, before
its msgstr>

=item C<FILE line N: an entry needs a msgid and a msgstr>

=item C<FILE line N: the same message as line M>

The same msgctxt and msgid twice.

=item C<FILE: no header entry (msgid "") opens the file>, or C<the header
(msgid "") must be the first entry>

=item C<FILE line N: header line 'LINE' is not 'Field: value'>

=item C<FILE: the header must declare charset=UTF-8>

=item C<FILE line N: K plural forms where Plural-Forms declares M>, or C<a
plural entry, but the header has no Plural-Forms>

=back

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>, L<Mojo::File>, L<Mojo::Util>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

UTF-8 only: a file declaring another charset is refused rather than
converted. Octal, hexadecimal and the rarer C escapes (C<\a>, C<\f>, ...)
are refused, as are compiled MO files.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
