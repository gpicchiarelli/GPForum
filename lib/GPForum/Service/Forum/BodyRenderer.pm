# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::BodyRenderer;

use Const::Fast;
use List::Util qw(any first);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::Util qw(xml_escape);

our $VERSION = '0.001';

const my $STRONG_MARK   => q{**};
const my $EMPHASIS_MARK => q{*};
const my $LINK_CLOSE    => q{](};
const my $KEEP_TRAILING => -1;
const my $INDEX_MISS    => -1;
const my $REL_SAFE      => 'nofollow noopener noreferrer';
const my @SAFE_SCHEMES  => ( 'https://', 'http://', 'mailto:' );

# A line, with or without its newline, that opens a fence (three backticks
# and an info string with no backtick) or closes one (three backticks and
# spaces), indented by at most three spaces.
const my $OPEN_FENCE  => qr/\A [ ]{0,3} ``` [^`\n]* \n? \z/msx;
const my $CLOSE_FENCE => qr/\A [ ]{0,3} ``` [ ]* \n? \z/msx;

# A code span: backticks around text on one line.
const my $CODE_SPAN => qr/( ` [^`\n]+ ` )/msx;

# Bodies kept rendered: a page's worth of hot threads, at a few KB each.
const my $RENDERED_LIMIT => 2048;

# A body renders to the same HTML every time, and a thread page renders its
# 25 bodies on every read, so the HTML is kept by source. The memo is
# cleared when full rather than kept in order: a bound is all it needs.
my %RENDERED;

sub render_safe ( $self, $source ) {
    if ( !defined $source || !length $source ) {
        return q{};
    }
    return $RENDERED{$source} if exists $RENDERED{$source};

    if ( keys %RENDERED >= $RENDERED_LIMIT ) {
        %RENDERED = ();
    }

    return $RENDERED{$source} = _render($source);
}

sub _render ($source) {
    my $text = $source =~ s/\r\n?/\n/gmsxr;

    return _joined(
        map {
            $_->{type} eq 'fence'
              ? '<pre>' . _code_html( $_->{text} ) . '</pre>'
              : _prose_html( $_->{text} )
        } @{ _tokens($text) }
    );
}

# The source cut into fences and the prose between them. A fence is the lines
# between an opening line and the first closing line below it; an opening
# line that is never closed is prose, up to the next line that opens one.
sub _tokens ($text) {
    my @lines = split /(?<=\n)/msx, $text;
    my @tokens;
    my $at = 0;
    while ( $at < @lines ) {
        my $closing = _fence_close( \@lines, $at );
        if ( defined $closing ) {
            my $body = join q{}, @lines[ $at + 1 .. $closing - 1 ];
            push @tokens, { text => $body =~ s/\n\z//msxr, type => 'fence' };
            $at = $closing + 1;
            next;
        }

        my $end = first { $lines[$_] =~ $OPEN_FENCE } $at + 1 .. $#lines;
        $end //= scalar @lines;
        push @tokens,
          { text => join( q{}, @lines[ $at .. $end - 1 ] ), type => 'prose' };
        $at = $end;
    }

    return \@tokens;
}

# The index of the line that closes the fence line $at opens, or undef when
# it opens none: an opening line needs its newline and a closing line below.
sub _fence_close ( $lines, $at ) {
    if ( $lines->[$at] !~ $OPEN_FENCE || $lines->[$at] !~ /\n\z/msx ) {
        return undef;
    }

    return first { $lines->[$_] =~ $CLOSE_FENCE } $at + 1 .. $#{$lines};
}

# Prose is paragraphs and block quotes: a run of quoted lines is one quote, a
# run of other lines one paragraph block, and a blank line ends either.
sub _prose_html ($text) {
    if ( $text !~ /\S/msx ) {
        return q{};
    }

    my @blocks;
    my $current;
    for my $line ( split /\n/msx, $text, $KEEP_TRAILING ) {
        my $quoted =
            $line =~ /\A [ ]{0,3} > /msx
          ? $line =~ s/\A [ ]{0,3} > [ ]?//msxr
          : undef;
        if ( !defined $quoted && $line !~ /\S/msx ) {
            $current = undef;
            next;
        }

        my $type = defined $quoted ? 'quote' : 'paragraph';
        if ( !$current || $current->{type} ne $type ) {
            $current = { lines => [], type => $type };
            push @blocks, $current;
        }
        push @{ $current->{lines} }, $quoted // $line;
    }

    return _joined(
        map {
            $_->{type} eq 'quote'
              ? '<blockquote>'
              . _paragraphs_html( $_->{lines} )
              . '</blockquote>'
              : _paragraphs_html( $_->{lines} )
        } @blocks
    );
}

# One paragraph for each run of non-blank lines, its lines joined by <br>.
sub _paragraphs_html ($lines) {
    my @chunks = ( [] );
    for my $line ( @{$lines} ) {
        if ( $line !~ /\S/msx ) {
            push @chunks, [];
            next;
        }
        push @{ $chunks[-1] }, $line;
    }

    return _joined(
        map  { '<p>' . _inline( join "\n", @{$_} ) . '</p>' }
        grep { @{$_} } @chunks
    );
}

# A paragraph's text is its code spans and what lies between them. A span is
# only escaped, so what it holds is shown as typed; the rest goes on to links
# and emphasis. A backtick with no partner on its line stays a backtick.
sub _inline ($raw) {
    my $html = join q{}, map {
        /\A ` ( [^`\n]+ ) ` \z/msx
          ? _code_html($1)
          : _emphasis( _links( xml_escape($_) ) )
    } split $CODE_SPAN, $raw;

    return $html =~ s/\n/<br>/gmsxr;
}

# Links in escaped text: [label](url), not after a "!" (an image), with a
# URL _link_at accepts. Any other "[" stays as typed.
sub _links ($text) {
    my $out = q{};
    my $pos = 0;
    while ( ( my $open = index $text, '[', $pos ) != $INDEX_MISS ) {
        my $link = _link_at( $text, $open );
        if ( !$link ) {
            $out .= substr $text, $pos, $open - $pos + 1;
            $pos = $open + 1;
            next;
        }
        $out .= substr( $text, $pos, $open - $pos ) . $link->{html};
        $pos = $link->{end};
    }

    return $out . substr $text, $pos;
}

# The anchor for the link opening at $open, and where it ends; undef unless
# its URL, already escaped, holds no entity but &amp; and no space and starts
# with an allowed scheme.
sub _link_at ( $text, $open ) {
    if ( $open > 0 && substr( $text, $open - 1, 1 ) eq q{!} ) {
        return undef;
    }
    my $mid = index $text, $LINK_CLOSE, $open + 1;
    if ( $mid == $INDEX_MISS ) {
        return undef;
    }
    my $url_start = $mid + length $LINK_CLOSE;
    my $link_end  = index $text, ')', $url_start;
    if ( $link_end == $INDEX_MISS ) {
        return undef;
    }

    my $url    = substr $text, $url_start, $link_end - $url_start;
    my $probe  = $url =~ s/&amp;//gmsxr;
    my $scheme = lc $url;
    if (   index( $probe, q{&} ) != $INDEX_MISS
        || $probe =~ /[[:space:]]/msx
        || !( any { index( $scheme, $_ ) == 0 } @SAFE_SCHEMES ) )
    {
        return undef;
    }

    my $label = substr $text, $open + 1, $mid - $open - 1;
    return {
        end  => $link_end + 1,
        html => '<a href="'
          . $url
          . '" rel="'
          . $REL_SAFE . q{">}
          . $label . '</a>',
    };
}

# Emphasis runs after _links, so the string already contains the anchors that
# pass emitted -- and xml_escape ran before both, so any angle bracket left in
# it is a tag this renderer produced, not user text. Marking up across one
# rewrote the URL: [docs](https://example.com/a*b*c) came out as
# href="https://example.com/a<em>b</em>c", with HTML tags inside an attribute.
#
# Emphasis is applied to the text between tags instead, never inside one. The
# cost is that a pair cannot span a link -- `*before [x](y) after*` no longer
# emphasises -- which is a fair trade against corrupting the href, and keeps
# `[*text*](url)` working because the link text is its own segment.
sub _emphasis ($text) {
    return join q{}, map {
        substr( $_, 0, 1 ) eq q{<}
          ? $_
          : _wrap_pairs( _wrap_pairs( $_, $STRONG_MARK, 'strong' ),
            $EMPHASIS_MARK, 'em' )
    } split /(< [^>]* >)/msx, $text;
}

# Each pair of $mark around text on one line becomes that text in <$tag>; a
# mark with no partner, or around nothing, stays as typed.
sub _wrap_pairs ( $text, $mark, $tag ) {
    my $width = length $mark;
    my $out   = q{};
    my $pos   = 0;
    while ( $pos < length $text ) {
        my $start = index $text, $mark, $pos;
        if ( $start == $INDEX_MISS ) {
            last;
        }
        my $end = index $text, $mark, $start + $width;
        if ( $end == $INDEX_MISS ) {
            last;
        }

        my $inner = substr $text, $start + $width, $end - $start - $width;
        if ( !length $inner || index( $inner, "\n" ) != $INDEX_MISS ) {
            $out .= substr $text, $pos, $start + $width - $pos;
            $pos = $start + $width;
            next;
        }
        $out .= substr( $text, $pos, $start - $pos ) . "<$tag>$inner</$tag>";
        $pos = $end + $width;
    }

    return $out . substr $text, $pos;
}

sub _code_html ($text) {
    return '<code>' . xml_escape($text) . '</code>';
}

sub _joined (@parts) {
    return join "\n", grep { length } @parts;
}

1;

__END__

=head1 NAME

GPForum::Service::Forum::BodyRenderer - Safe markdown subset for post bodies.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $html = GPForum::Service::Forum::BodyRenderer->new->render_safe($source);

=head1 DESCRIPTION

Turns post C<body_source> into sanitized HTML for
C<post_bodies.body_rendered_safe> and forum post presenters. Input is escaped
before any markup is introduced. The allowed subset is emphasis, http/https/mailto
links, block quotes, fenced code, and code spans between backticks on one
line. Raw HTML, inline images, and @mentions are not interpreted.

=head1 SUBROUTINES/METHODS

=head2 render_safe

Returns sanitized HTML for the supplied markdown source. Undefined or empty
source yields an empty string.

=head1 DIAGNOSTICS

None. Invalid or unsafe constructs are escaped and left as text.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<List::Util>, L<Mojo::Base>, and L<Mojo::Util>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Inline images and @mention highlighting are intentionally left as literal
text. Heading, list, and raw-HTML markdown are not implemented. A code span is
read before links and emphasis, so neither can reach across one.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
