package GPForum::Service::Forum::BodyRenderer;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;
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

sub render_safe {
    my ( $self, $source ) = @_;

    if ( !defined $source ) {
        return q{};
    }

    return $self->_render_text($source);
}

sub _render_text {
    my ( $self, $source ) = @_;

    if ( !length $source ) {
        return q{};
    }

    return $self->_join_html( $self->_render_tokens( _tokens($source) ) );
}

sub _render_tokens {
    my ( $self, $tokens ) = @_;

    return [ map { $self->_render_token($_) } @{$tokens} ];
}

sub _render_token {
    my ( $self, $token ) = @_;

    if ( $token->{type} eq 'fence' ) {
        return _fence_html( $token->{text} );
    }

    return $self->_render_prose( $token->{text} );
}

sub _join_html {
    my ( undef, $parts ) = @_;

    return join "\n", grep { length } @{$parts};
}

sub _tokens {
    my ($source) = @_;

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

sub _has_remaining {
    my ($state) = @_;

    if ( $state->{pos} < length $state->{text} ) {
        return 1;
    }

    return 0;
}

sub _take_next {
    my ($state) = @_;

    if ( _fence_open_at($state) ) {
        _take_fence($state);
        return;
    }

    _take_prose($state);
    return;
}

sub _fence_open_at {
    my ($state) = @_;

    if ( !_at_line_start($state) ) {
        return 0;
    }

    return _is_open_fence_line( _line_from( $state, $state->{pos} ) );
}

sub _at_line_start {
    my ($state) = @_;

    if ( $state->{pos} == 0 ) {
        return 1;
    }

    if ( substr( $state->{text}, $state->{pos} - 1, 1 ) eq "\n" ) {
        return 1;
    }

    return 0;
}

sub _take_fence {
    my ($state) = @_;

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

sub _closing_fence {
    my ( $state, $from ) = @_;

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
            return;
        }
        $pos = $next;
    }

    return;
}

sub _fence_body {
    my ( $state, $start, $end ) = @_;

    my $body = substr $state->{text}, $start, $end - $start;
    $body =~ s/\n \z//msx;

    return $body;
}

sub _take_prose {
    my ($state) = @_;

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

sub _prose_end {
    my ($state) = @_;

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

sub _line_from {
    my ( $state, $pos ) = @_;

    my $nl = index $state->{text}, "\n", $pos;
    if ( $nl == $INDEX_MISS ) {
        return substr $state->{text}, $pos;
    }

    return substr $state->{text}, $pos, $nl - $pos;
}

sub _next_line_start {
    my ( $state, $pos ) = @_;

    my $nl = index $state->{text}, "\n", $pos;
    if ( $nl == $INDEX_MISS ) {
        return;
    }

    return $nl + 1;
}

sub _is_open_fence_line {
    my ($line) = @_;

    if ( $line =~ /\A [ ]{0,3} ``` [^`]* \z/msx ) {
        return 1;
    }

    return 0;
}

sub _is_close_fence_line {
    my ($line) = @_;

    if ( $line =~ /\A [ ]{0,3} ``` [ ]* \z/msx ) {
        return 1;
    }

    return 0;
}

sub _render_prose {
    my ( $self, $text ) = @_;

    if ( $text !~ /\S/msx ) {
        return q{};
    }

    return $self->_join_html( $self->_render_flow( _flow_blocks($text) ) );
}

sub _render_flow {
    my ( $self, $blocks ) = @_;

    return [ map { $self->_render_flow_block($_) } @{$blocks} ];
}

sub _render_flow_block {
    my ( $self, $block ) = @_;

    if ( $block->{type} eq 'quote' ) {
        return _wrap_quote( $self->_paragraphs( $block->{lines} ) );
    }

    return $self->_paragraphs( $block->{lines} );
}

sub _paragraphs {
    my ( $self, $lines ) = @_;

    my $chunks = _paragraph_chunks($lines);

    return $self->_join_html( [ map { $self->_paragraph($_) } @{$chunks} ] );
}

sub _paragraph {
    my ( $self, $lines ) = @_;

    my $raw = join "\n", @{$lines};
    if ( $raw !~ /\S/msx ) {
        return q{};
    }

    return _wrap_paragraph( $self->_inline($raw) );
}

sub _inline {
    my ( undef, $raw ) = @_;

    return _breaks( _emphasis( _links( xml_escape($raw) ) ) );
}

sub _flow_blocks {
    my ($text) = @_;

    my $state = { blocks => [], current => undef };
    for my $line ( @{ _lines($text) } ) {
        _consume_line( $state, $line );
    }
    _flush_block($state);

    return $state->{blocks};
}

sub _consume_line {
    my ( $state, $line ) = @_;

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

sub _push_line {
    my ( $state, $type, $line ) = @_;

    if ( !_same_type( $state, $type ) ) {
        _flush_block($state);
        $state->{current} = { lines => [], type => $type };
    }
    push @{ $state->{current}{lines} }, $line;
    return;
}

sub _same_type {
    my ( $state, $type ) = @_;

    if ( !$state->{current} ) {
        return 0;
    }
    if ( $state->{current}{type} eq $type ) {
        return 1;
    }

    return 0;
}

sub _flush_block {
    my ($state) = @_;

    if ( !$state->{current} ) {
        return;
    }
    push @{ $state->{blocks} }, $state->{current};
    $state->{current} = undef;
    return;
}

sub _paragraph_chunks {
    my ($lines) = @_;

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

sub _store_chunk {
    my ( $chunks, $current ) = @_;

    if ( !@{$current} ) {
        return;
    }
    push @{$chunks}, [ @{$current} ];
    return;
}

sub _lines {
    my ($text) = @_;

    return [ split /\n/msx, $text, $KEEP_TRAILING ];
}

sub _is_blank {
    my ($line) = @_;

    if ( $line =~ /\S/msx ) {
        return 0;
    }

    return 1;
}

sub _is_quote_line {
    my ($line) = @_;

    if ( defined _quote_text($line) ) {
        return 1;
    }

    return 0;
}

sub _quote_text {
    my ($line) = @_;

    my $stripped = $line;
    $stripped =~ s/\A [ ]{0,3} > [ ]?//msx;
    if ( $stripped eq $line ) {
        return;
    }

    return $stripped;
}

sub _links {
    my ($text) = @_;

    my $state = { out => q{}, pos => 0, text => $text };
    while ( _advance_link($state) ) { }

    return $state->{out};
}

sub _advance_link {
    my ($state) = @_;

    my $open = index $state->{text}, '[', $state->{pos};
    if ( $open == $INDEX_MISS ) {
        $state->{out} .= substr $state->{text}, $state->{pos};
        return 0;
    }

    _emit_link_or_skip( $state, $open );
    return 1;
}

sub _emit_link_or_skip {
    my ( $state, $open ) = @_;

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

sub _parse_link {
    my ( $text, $open ) = @_;

    if ( _is_image_marker( $text, $open ) ) {
        return;
    }

    my $mid = index $text, $LINK_CLOSE, $open + 1;
    if ( $mid == $INDEX_MISS ) {
        return;
    }

    my $link_end = index $text, ')', $mid + length $LINK_CLOSE;
    if ( $link_end == $INDEX_MISS ) {
        return;
    }

    return _link_from_span( $text, $open, $mid, $link_end );
}

sub _is_image_marker {
    my ( $text, $open ) = @_;

    if ( $open == 0 ) {
        return 0;
    }
    if ( substr( $text, $open - 1, 1 ) eq q{!} ) {
        return 1;
    }

    return 0;
}

sub _link_from_span {
    my ( $text, $open, $mid, $link_end ) = @_;

    my $label = substr $text, $open + 1, $mid - $open - 1;
    my $url   = substr $text, $mid + length $LINK_CLOSE,
      $link_end - $mid - length $LINK_CLOSE;
    if ( !_safe_url($url) ) {
        return;
    }

    return {
        end  => $link_end + 1,
        html => _anchor_html( $label, $url ),
    };
}

sub _safe_url {
    my ($url) = @_;

    if ( !_plain_url_chars($url) ) {
        return 0;
    }

    return _allowed_scheme($url);
}

sub _plain_url_chars {
    my ($url) = @_;

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

sub _allowed_scheme {
    my ($url) = @_;

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

sub _has_prefix {
    my ( $value, $prefix ) = @_;

    if ( index( $value, $prefix ) == 0 ) {
        return 1;
    }

    return 0;
}

sub _anchor_html {
    my ( $label, $url ) = @_;

    return '<a href="' . $url . '" rel="' . $REL_SAFE . q{">} . $label . '</a>';
}

sub _emphasis {
    my ($text) = @_;

    return _wrap_pairs( _wrap_pairs( $text, $STRONG_MARK, \&_strong_html ),
        $EMPHASIS_MARK, \&_em_html );
}

sub _wrap_pairs {
    my ( $text, $mark, $wrapper ) = @_;

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

sub _scan_mark {
    my ($state) = @_;

    my $start = index $state->{text}, $state->{mark}, $state->{pos};
    if ( $start == $INDEX_MISS ) {
        $state->{out} .= substr $state->{text}, $state->{pos};
        $state->{pos} = length $state->{text};
        return;
    }

    _try_wrap_mark( $state, $start );
    return;
}

sub _try_wrap_mark {
    my ( $state, $start ) = @_;

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

sub _commit_mark {
    my ( $state, $start, $end ) = @_;

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

sub _usable_span {
    my ($inner) = @_;

    if ( !length $inner ) {
        return 0;
    }
    if ( index( $inner, "\n" ) >= 0 ) {
        return 0;
    }

    return 1;
}

sub _breaks {
    my ($text) = @_;

    $text =~ s/\n/<br>/gmsx;
    return $text;
}

sub _lf {
    my ($text) = @_;

    $text =~ s/\r\n/\n/gmsx;
    $text =~ s/\r/\n/gmsx;
    return $text;
}

sub _fence_html {
    my ($text) = @_;

    return '<pre><code>' . xml_escape($text) . '</code></pre>';
}

sub _wrap_quote {
    my ($html) = @_;

    return '<blockquote>' . $html . '</blockquote>';
}

sub _wrap_paragraph {
    my ($html) = @_;

    return '<p>' . $html . '</p>';
}

sub _strong_html {
    my ($html) = @_;

    return '<strong>' . $html . '</strong>';
}

sub _em_html {
    my ($html) = @_;

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
