# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::BodyRenderer;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;
use Mojo::Util qw(xml_escape);

our $VERSION = '0.001';

const my $FENCE_MARK    => q{```};
const my $STRONG_MARK   => q{**};
const my $EMPHASIS_MARK => q{*};
const my $LINK_CLOSE    => q{](};
const my $KEEP_TRAILING => -1;
const my $INDEX_MISS    => -1;
const my $REL_SAFE      => 'nofollow noopener noreferrer';
const my $HTTP_PREFIX   => 'http://';
const my $HTTPS_PREFIX  => 'https://';
const my $MAILTO_PREFIX => 'mailto:';

sub render_safe ( $self, $source ) {
    if ( !defined $source ) {
        return q{};
    }

    return $self->_render_text($source);
}

sub _render_text ( $self, $source ) {
    if ( !length $source ) {
        return q{};
    }

    return $self->_join_html( $self->_render_tokens( _tokens($source) ) );
}

sub _render_tokens ( $self, $tokens ) {
    return [ map { $self->_render_token($_) } @{$tokens} ];
}

sub _render_token ( $self, $token ) {
    if ( $token->{type} eq 'fence' ) {
        return _fence_html( $token->{text} );
    }

    return $self->_render_prose( $token->{text} );
}

sub _join_html ( $, $parts ) {
    return join "\n", grep { length } @{$parts};
}

sub _tokens ($source) {
    my $state = {
        parts => [],
        pos   => 0,
        text  => _lf($source),
    };
    while ( _has_remaining($state) ) {
        _take_next($state);
    }

    return $state->{parts};
}

sub _has_remaining ($state) {
    if ( $state->{pos} < length $state->{text} ) {
        return 1;
    }

    return 0;
}

sub _take_next ($state) {
    if ( _fence_open_at($state) ) {
        _take_fence($state);
        return;
    }

    _take_prose($state);
    return;
}

sub _fence_open_at ($state) {
    if ( !_at_line_start($state) ) {
        return 0;
    }

    return _is_open_fence_line( _line_from( $state, $state->{pos} ) );
}

sub _at_line_start ($state) {
    if ( $state->{pos} == 0 ) {
        return 1;
    }

    if ( substr( $state->{text}, $state->{pos} - 1, 1 ) eq "\n" ) {
        return 1;
    }

    return 0;
}

sub _take_fence ($state) {
    my $after_open = _next_line_start( $state, $state->{pos} );
    if ( !defined $after_open ) {
        _take_prose($state);
        return;
    }

    my $fence_end = _closing_fence( $state, $after_open );
    if ( !defined $fence_end ) {
        _take_prose($state);
        return;
    }

    push @{ $state->{parts} },
      {
        text => _fence_body( $state, $after_open, $fence_end->{start} ),
        type => 'fence',
      };
    $state->{pos} = $fence_end->{end};
    return;
}

sub _closing_fence ( $state, $from ) {
    my $undefined;

    my $pos = $from;
    while ( $pos <= length $state->{text} ) {
        my $line = _line_from( $state, $pos );
        if ( _is_close_fence_line($line) ) {
            return {
                end => _next_line_start( $state, $pos )
                  // length $state->{text},
                start => $pos,
            };
        }
        my $next = _next_line_start( $state, $pos );
        if ( !defined $next ) {
            return $undefined;
        }
        $pos = $next;
    }

    return $undefined;
}

sub _fence_body ( $state, $start, $end ) {
    my $body = substr $state->{text}, $start, $end - $start;
    $body =~ s/\n \z//msx;

    return $body;
}

sub _take_prose ($state) {
    my $start = $state->{pos};
    my $end   = _prose_end($state);
    push @{ $state->{parts} },
      {
        text => substr( $state->{text}, $start, $end - $start ),
        type => 'prose',
      };
    $state->{pos} = $end;
    return;
}

sub _prose_end ($state) {
    my $pos = _next_line_start( $state, $state->{pos} );
    if ( !defined $pos ) {
        return length $state->{text};
    }

    while ( $pos < length $state->{text} ) {
        if ( _is_open_fence_line( _line_from( $state, $pos ) ) ) {
            return $pos;
        }
        my $next = _next_line_start( $state, $pos );
        if ( !defined $next ) {
            return length $state->{text};
        }
        $pos = $next;
    }

    return length $state->{text};
}

sub _line_from ( $state, $pos ) {
    my $nl = index $state->{text}, "\n", $pos;
    if ( $nl == $INDEX_MISS ) {
        return substr $state->{text}, $pos;
    }

    return substr $state->{text}, $pos, $nl - $pos;
}

sub _next_line_start ( $state, $pos ) {
    my $nl = index $state->{text}, "\n", $pos;
    if ( $nl == $INDEX_MISS ) {
        my $undefined;
        return $undefined;
    }

    return $nl + 1;
}

sub _is_open_fence_line ($line) {
    if ( $line =~ /\A [ ]{0,3} ``` [^`]* \z/msx ) {
        return 1;
    }

    return 0;
}

sub _is_close_fence_line ($line) {
    if ( $line =~ /\A [ ]{0,3} ``` [ ]* \z/msx ) {
        return 1;
    }

    return 0;
}

sub _render_prose ( $self, $text ) {
    if ( $text !~ /\S/msx ) {
        return q{};
    }

    return $self->_join_html( $self->_render_flow( _flow_blocks($text) ) );
}

sub _render_flow ( $self, $blocks ) {
    return [ map { $self->_render_flow_block($_) } @{$blocks} ];
}

sub _render_flow_block ( $self, $block ) {
    if ( $block->{type} eq 'quote' ) {
        return _wrap_quote( $self->_paragraphs( $block->{lines} ) );
    }

    return $self->_paragraphs( $block->{lines} );
}

sub _paragraphs ( $self, $lines ) {
    my $chunks = _paragraph_chunks($lines);

    return $self->_join_html( [ map { $self->_paragraph($_) } @{$chunks} ] );
}

sub _paragraph ( $self, $lines ) {
    my $raw = join "\n", @{$lines};
    if ( $raw !~ /\S/msx ) {
        return q{};
    }

    return _wrap_paragraph( $self->_inline($raw) );
}

sub _inline ( $, $raw ) {
    return _breaks( _emphasis( _links( xml_escape($raw) ) ) );
}

sub _flow_blocks ($text) {
    my $state = { blocks => [], current => undef };
    for my $line ( @{ _lines($text) } ) {
        _consume_line( $state, $line );
    }
    _flush_block($state);

    return $state->{blocks};
}

sub _consume_line ( $state, $line ) {
    if ( _is_quote_line($line) ) {
        _push_line( $state, 'quote', _quote_text($line) );
        return;
    }
    if ( _is_blank($line) ) {
        _flush_block($state);
        return;
    }

    _push_line( $state, 'paragraph', $line );
    return;
}

sub _push_line ( $state, $type, $line ) {
    if ( !_same_type( $state, $type ) ) {
        _flush_block($state);
        $state->{current} = { lines => [], type => $type };
    }
    push @{ $state->{current}{lines} }, $line;
    return;
}

sub _same_type ( $state, $type ) {
    if ( !$state->{current} ) {
        return 0;
    }
    if ( $state->{current}{type} eq $type ) {
        return 1;
    }

    return 0;
}

sub _flush_block ($state) {
    if ( !$state->{current} ) {
        return;
    }
    push @{ $state->{blocks} }, $state->{current};
    $state->{current} = undef;
    return;
}

sub _paragraph_chunks ($lines) {
    my @chunks;
    my $current = [];
    for my $line ( @{$lines} ) {
        if ( _is_blank($line) ) {
            _store_chunk( \@chunks, $current );
            $current = [];
            next;
        }
        push @{$current}, $line;
    }
    _store_chunk( \@chunks, $current );

    return \@chunks;
}

sub _store_chunk ( $chunks, $current ) {
    if ( !@{$current} ) {
        return;
    }
    push @{$chunks}, [ @{$current} ];
    return;
}

sub _lines ($text) {
    return [ split /\n/msx, $text, $KEEP_TRAILING ];
}

sub _is_blank ($line) {
    if ( $line =~ /\S/msx ) {
        return 0;
    }

    return 1;
}

sub _is_quote_line ($line) {
    if ( defined _quote_text($line) ) {
        return 1;
    }

    return 0;
}

sub _quote_text ($line) {
    my $stripped = $line;
    $stripped =~ s/\A [ ]{0,3} > [ ]?//msx;
    if ( $stripped eq $line ) {
        my $undefined;
        return $undefined;
    }

    return $stripped;
}

sub _links ($text) {
    my $state = { out => q{}, pos => 0, text => $text };
    while ( _advance_link($state) ) { }

    return $state->{out};
}

sub _advance_link ($state) {
    my $open = index $state->{text}, '[', $state->{pos};
    if ( $open == $INDEX_MISS ) {
        $state->{out} .= substr $state->{text}, $state->{pos};
        return 0;
    }

    _emit_link_or_skip( $state, $open );
    return 1;
}

sub _emit_link_or_skip ( $state, $open ) {
    my $parsed = _parse_link( $state->{text}, $open );
    if ( !$parsed ) {
        $state->{out} .= substr $state->{text}, $state->{pos},
          $open - $state->{pos} + 1;
        $state->{pos} = $open + 1;
        return;
    }

    $state->{out} .= substr $state->{text}, $state->{pos},
      $open - $state->{pos};
    $state->{out} .= $parsed->{html};
    $state->{pos} = $parsed->{end};
    return;
}

sub _parse_link ( $text, $open ) {
    my $undefined;

    if ( _is_image_marker( $text, $open ) ) {
        return $undefined;
    }

    my $mid = index $text, $LINK_CLOSE, $open + 1;
    if ( $mid == $INDEX_MISS ) {
        return $undefined;
    }

    my $link_end = index $text, ')', $mid + length $LINK_CLOSE;
    if ( $link_end == $INDEX_MISS ) {
        return $undefined;
    }

    return _link_from_span( $text, $open, $mid, $link_end );
}

sub _is_image_marker ( $text, $open ) {
    if ( $open == 0 ) {
        return 0;
    }
    if ( substr( $text, $open - 1, 1 ) eq q{!} ) {
        return 1;
    }

    return 0;
}

sub _link_from_span ( $text, $open, $mid, $link_end ) {
    my $label = substr $text, $open + 1, $mid - $open - 1;
    my $url   = substr $text, $mid + length $LINK_CLOSE,
      $link_end - $mid - length $LINK_CLOSE;
    if ( !_safe_url($url) ) {
        my $undefined;
        return $undefined;
    }

    return {
        end  => $link_end + 1,
        html => _anchor_html( $label, $url ),
    };
}

sub _safe_url ($url) {
    if ( !_plain_url_chars($url) ) {
        return 0;
    }

    return _allowed_scheme($url);
}

sub _plain_url_chars ($url) {
    my $probe = $url;
    $probe =~ s/&amp;//gmsx;
    if ( index( $probe, q{&} ) >= 0 ) {
        return 0;
    }
    if ( $probe =~ /[[:space:]]/msx ) {
        return 0;
    }

    return 1;
}

sub _allowed_scheme ($url) {
    my $normalized = lc $url;
    if ( _has_prefix( $normalized, $HTTPS_PREFIX ) ) {
        return 1;
    }
    if ( _has_prefix( $normalized, $HTTP_PREFIX ) ) {
        return 1;
    }
    if ( _has_prefix( $normalized, $MAILTO_PREFIX ) ) {
        return 1;
    }

    return 0;
}

sub _has_prefix ( $value, $prefix ) {
    if ( index( $value, $prefix ) == 0 ) {
        return 1;
    }

    return 0;
}

sub _anchor_html ( $label, $url ) {
    return '<a href="' . $url . '" rel="' . $REL_SAFE . q{">} . $label . '</a>';
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
    my @parts = split /(< [^>]* >)/msx, $text;
    for my $part (@parts) {
        next if substr( $part, 0, 1 ) eq q{<};
        $part = _wrap_pairs( _wrap_pairs( $part, $STRONG_MARK, \&_strong_html ),
            $EMPHASIS_MARK, \&_em_html );
    }

    return join q{}, @parts;
}

sub _wrap_pairs ( $text, $mark, $wrapper ) {
    my $state = {
        mark    => $mark,
        out     => q{},
        pos     => 0,
        text    => $text,
        wrapper => $wrapper,
    };
    while ( _has_remaining($state) ) {
        _scan_mark($state);
    }

    return $state->{out};
}

sub _scan_mark ($state) {
    my $start = index $state->{text}, $state->{mark}, $state->{pos};
    if ( $start == $INDEX_MISS ) {
        $state->{out} .= substr $state->{text}, $state->{pos};
        $state->{pos} = length $state->{text};
        return;
    }

    _try_wrap_mark( $state, $start );
    return;
}

sub _try_wrap_mark ( $state, $start ) {
    my $width = length $state->{mark};
    my $end   = index $state->{text}, $state->{mark}, $start + $width;
    if ( $end == $INDEX_MISS ) {
        $state->{out} .= substr $state->{text}, $state->{pos};
        $state->{pos} = length $state->{text};
        return;
    }

    _commit_mark( $state, $start, $end );
    return;
}

sub _commit_mark ( $state, $start, $end ) {
    my $width = length $state->{mark};
    my $inner = substr $state->{text}, $start + $width, $end - $start - $width;
    if ( !_usable_span($inner) ) {
        $state->{out} .= substr $state->{text}, $state->{pos},
          $start + $width - $state->{pos};
        $state->{pos} = $start + $width;
        return;
    }

    $state->{out} .= substr $state->{text}, $state->{pos},
      $start - $state->{pos};
    $state->{out} .= $state->{wrapper}->($inner);
    $state->{pos} = $end + $width;
    return;
}

sub _usable_span ($inner) {
    if ( !length $inner ) {
        return 0;
    }
    if ( index( $inner, "\n" ) >= 0 ) {
        return 0;
    }

    return 1;
}

sub _breaks ($text) {
    $text =~ s/\n/<br>/gmsx;
    return $text;
}

sub _lf ($text) {
    $text =~ s/\r\n/\n/gmsx;
    $text =~ s/\r/\n/gmsx;
    return $text;
}

sub _fence_html ($text) {
    return '<pre><code>' . xml_escape($text) . '</code></pre>';
}

sub _wrap_quote ($html) {
    return '<blockquote>' . $html . '</blockquote>';
}

sub _wrap_paragraph ($html) {
    return '<p>' . $html . '</p>';
}

sub _strong_html ($html) {
    return '<strong>' . $html . '</strong>';
}

sub _em_html ($html) {
    return '<em>' . $html . '</em>';
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
links, block quotes, and fenced code. Raw HTML, inline images, and @mentions are
not interpreted.

=head1 SUBROUTINES/METHODS

=head2 render_safe

Returns sanitized HTML for the supplied markdown source. Undefined or empty
source yields an empty string.

=head1 DIAGNOSTICS

None. Invalid or unsafe constructs are escaped and left as text.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<Mojo::Base>, and L<Mojo::Util>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Inline images and @mention highlighting are intentionally left as literal
text. Heading, list, and raw-HTML markdown are not implemented.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
