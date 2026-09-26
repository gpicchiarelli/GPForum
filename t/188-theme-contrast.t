# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Test::More;

use lib 'lib';

our $VERSION = '0.001';

# The README claims WCAG 2.2 AA. These are the two thresholds that claim
# implies: 3:1 for the boundary of a user interface component (1.4.11
# non-text contrast) and 4.5:1 for body text (1.4.3).
const my $NON_TEXT_MINIMUM => 3;
const my $TEXT_MINIMUM     => 4.5;

const my $STYLESHEET => 'assets/css/gpforum-ssr.css';

# The constants of the WCAG relative-luminance formula, named so the arithmetic
# below can be checked against the specification rather than read as magic.
const my $LUMINANCE_OFFSET  => 0.05;
const my $SRGB_KNEE         => 0.03928;
const my $SRGB_LOW_DIVISOR  => 12.92;
const my $SRGB_OFFSET       => 0.055;
const my $SRGB_SCALE        => 1.055;
const my $SRGB_EXPONENT     => 2.4;
const my $RED_COEFFICIENT   => 0.2126;
const my $GREEN_COEFFICIENT => 0.7152;
const my $BLUE_COEFFICIENT  => 0.0722;
const my $CHANNEL_MAXIMUM   => 255;

# The default theme failed 1.4.11 at 1.57:1 against the surface and 1.40:1
# against the alternate surface, on every form field, card and table border.
# `mark` was a hardcoded light-theme hex with no dark variant, so in dark mode
# it put the light foreground on a light highlight at 1.28:1 -- unreadable.
# Computing the ratios here is what keeps a future colour change honest.
my %light = _tokens_in_block( ':root',                   0 );
my %dark  = _tokens_in_block( 'html[data-theme="dark"]', 1 );

_contrast_ok( \%light, 'color-border', 'color-surface', $NON_TEXT_MINIMUM,
    'light: component borders against the surface' );
_contrast_ok( \%light, 'color-border', 'color-surface-alt', $NON_TEXT_MINIMUM,
    'light: component borders against the alternate surface' );
_contrast_ok( \%dark, 'color-border', 'color-surface', $NON_TEXT_MINIMUM,
    'dark: component borders against the surface' );
_contrast_ok( \%dark, 'color-border', 'color-surface-alt', $NON_TEXT_MINIMUM,
    'dark: component borders against the alternate surface' );

_contrast_ok( \%light, 'color-foreground', 'color-surface', $TEXT_MINIMUM,
    'light: body text against the surface' );
_contrast_ok( \%dark, 'color-foreground', 'color-surface', $TEXT_MINIMUM,
    'dark: body text against the surface' );

_contrast_ok( \%light, 'color-foreground', 'color-mark', $TEXT_MINIMUM,
    'light: text inside a highlight' );
_contrast_ok( \%dark, 'color-foreground', 'color-mark', $TEXT_MINIMUM,
    'dark: text inside a highlight' );

# A highlight nobody can see is not a highlight.
_contrast_ok( \%dark, 'color-mark', 'color-surface', $NON_TEXT_MINIMUM,
    'dark: the highlight is distinguishable from the surface' );

like(
    _stylesheet(),
    qr/background: \s* var[(]--color-mark[)]/msx,
    'mark reads a token rather than a hardcoded hex'
);

# The destructive-action button (ADR 0079) and the band around it: the
# button's label on red, and the consequence and hover in red on the pale band.
for my $palette ( [ light => \%light ], [ dark => \%dark ] ) {
    my ( $name, $tokens ) = @{$palette};
    _contrast_ok( $tokens, 'color-text-on-danger', 'color-danger',
        $TEXT_MINIMUM, "$name: a danger button's label" );
    _contrast_ok( $tokens, 'color-danger', 'color-surface-danger',
        $TEXT_MINIMUM, "$name: a consequence stated in the danger band" );
}
my $danger_rule       = qr/[.]button--danger \s* [{] [^}]*/msx;
my $danger_background = qr/background: \s* var[(]--color-danger[)]/msx;
like(
    _stylesheet(),
    qr/$danger_rule$danger_background/msx,
    'the danger button reads the danger token'
);

# 7.6: metadata lines carry usernames, and uppercasing them destroyed their
# case -- @perf_user_1 read as @PERF_USER_1 -- and screen readers may spell
# an uppercased word out letter by letter.
my ($meta_rule) = _stylesheet() =~ /^[.]ui-meta [ ] [{] ([^}]*) [}]/msx;
ok( defined $meta_rule, 'the stylesheet styles metadata lines' );
unlike( $meta_rule // q{},
    qr/text-transform/msx, 'without transforming their case' );

# 7.4: a stylesheet may name only fonts the visitor already has or that it
# ships. Inter was declared first in the stack with no @font-face and no font
# files, so the design depended on whatever the visitor had installed.
const my %SYSTEM_FAMILY => map { $_ => 1 } (
    'system-ui',  '-apple-system',  'Segoe UI',       'Roboto',
    'Noto Sans',  'Helvetica Neue', 'Helvetica',      'Arial',
    'sans-serif', 'ui-monospace',   'SFMono-Regular', 'Menlo',
    'Consolas',   'monospace',
);
my $css     = _stylesheet();
my %shipped = map { $_ => 1 }
  $css =~ /\@font-face \s* [{] [^}]* font-family: \s* ["']? ([^"';]+)/gmsx;
my @unshipped;
while ( $css =~ /--font-(?!size)[\w-]+: \s* ([^;]+);/gmsx ) {
    for my $family ( split /\s* , \s*/msx, $1 ) {
        $family =~ s/\A ["'] | ["'] \z//gmsx;
        next if $family =~ /\A var[(]/msx;
        next if exists $SYSTEM_FAMILY{$family} || exists $shipped{$family};
        push @unshipped, $family;
    }
}
is_deeply( \@unshipped, [],
    'every font the stylesheet names is shipped or a system font' );

done_testing();

sub _contrast_ok {    ## no critic (Subroutines::ProhibitManyArgs)
        # Two colours, a threshold and a label: collapsing them into a hashref
        # would make every call site longer than the assertion it makes.
    my ( $tokens, $front, $back, $minimum, $label ) = @_;

    my $one   = $tokens->{$front} or return fail("$label: no --$front");
    my $two   = $tokens->{$back}  or return fail("$label: no --$back");
    my $ratio = _ratio( $one, $two );

    return cmp_ok( $ratio, '>=', $minimum,
        sprintf '%s (%s on %s is %.2f:1, needs %s:1)',
        $label, $one, $two, $ratio, $minimum );
}

sub _ratio {
    my ( $one, $two ) = @_;

    my @sorted = sort { $a <=> $b } ( _luminance($one), _luminance($two) );

    return ( $sorted[1] + $LUMINANCE_OFFSET ) /
      ( $sorted[0] + $LUMINANCE_OFFSET );
}

sub _luminance {
    my ($colour) = @_;

    my @channel = map { hex } $colour =~ /\A [#] (..) (..) (..) \z/msx;
    my @linear  = map { _linear( $_ / $CHANNEL_MAXIMUM ) } @channel;

    return ( $RED_COEFFICIENT * $linear[0] ) +
      ( $GREEN_COEFFICIENT * $linear[1] ) +
      ( $BLUE_COEFFICIENT * $linear[2] );
}

sub _linear {
    my ($value) = @_;

    return $value / $SRGB_LOW_DIVISOR if $value <= $SRGB_KNEE;

    return ( ( $value + $SRGB_OFFSET ) / $SRGB_SCALE )**$SRGB_EXPONENT;
}

# The first block is the light theme at :root; the dark theme redefines the
# same tokens under html[data-theme="dark"], so it inherits whatever it does
# not name.
sub _tokens_in_block {
    my ( $marker, $inherit_light ) = @_;

    my $text  = _stylesheet();
    my $start = index $text, $marker;
    croak "block $marker not found" if $start < 0;
    my $open      = index $text, '{', $start;
    my $block_end = index $text, '}', $open;
    croak "block $marker is not closed" if $block_end < 0;

    # To the closing brace, not a fixed span: reading past it picked up the
    # high-contrast theme's tokens and tested the wrong palette.
    my $chunk = substr $text, $open, $block_end - $open;

    my %token;
    if ($inherit_light) {
        %token = _tokens_in_block( ':root', 0 );
    }
    while (
        $chunk =~ /--([[:lower:]-]+) \s* : \s* (\#[[:xdigit:]]{6}) \s* ;/gmsx )
    {
        $token{$1} = $2;
    }

    return %token;
}

sub _stylesheet {
    open my $handle, '<', $STYLESHEET or croak "open $STYLESHEET: $ERRNO";
    local $INPUT_RECORD_SEPARATOR = undef;
    my $text = <$handle>;
    close $handle or croak "close $STYLESHEET: $ERRNO";

    return $text;
}

1;
