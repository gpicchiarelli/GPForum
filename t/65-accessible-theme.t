package main;

use strict;
use warnings;

use Const::Fast;
use Mojo::File qw(path);
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Theme::Registry;

our $VERSION = '0.001';

const my $HTTP_OK             => 200;
const my $WCAG_AA             => 4.5;
const my $WCAG_AAA            => 7;
const my $HEX_BASE            => 16;
const my $CHANNEL_MAX         => 255;
const my $SRGB_LIMIT          => 0.03928;
const my $SRGB_OFFSET         => 0.055;
const my $SRGB_DIVISOR        => 1.055;
const my $SRGB_POWER          => 2.4;
const my $SRGB_LINEAR_DIVISOR => 12.92;
const my $RED_WEIGHT          => 0.2126;
const my $GREEN_WEIGHT        => 0.7152;
const my $BLUE_WEIGHT         => 0.0722;
const my $RATIO_OFFSET        => 0.05;

my $css      = path('assets/css/gpforum-ssr.css')->slurp;
my %tokens   = _root_tokens($css);
my $registry = GPForum::Theme::Registry->new;

is( $tokens{'color-background'},
    '#f8f6ef', 'SSR theme background comes from the logo paper color' );
is( $tokens{'color-foreground'},
    '#111412', 'SSR theme foreground comes from the logo ink color' );
is( $tokens{'color-primary'},
    '#214237', 'SSR theme primary comes from the logo forest color' );
is( $tokens{'color-secondary'},
    '#3f5f72', 'SSR theme secondary comes from the logo steel color' );
is( $tokens{'color-accent'}, '#a6532f',
    'SSR theme accent comes from the logo copper color' );

cmp_ok( _contrast( $tokens{'color-foreground'}, $tokens{'color-background'} ),
    '>=', $WCAG_AAA, 'normal foreground text passes WCAG AAA contrast' );
cmp_ok( _contrast( $tokens{'color-muted'}, $tokens{'color-background'} ),
    '>=', $WCAG_AAA, 'muted UI text passes WCAG AAA contrast' );
cmp_ok( _contrast( $tokens{'color-primary'}, $tokens{'color-background'} ),
    '>=', $WCAG_AAA, 'primary links pass WCAG AAA contrast' );
cmp_ok( _contrast( '#ffffff', $tokens{'color-primary'} ),
    '>=', $WCAG_AAA, 'primary button text passes WCAG AAA contrast' );
cmp_ok( _contrast( '#ffffff', $tokens{'color-secondary'} ),
    '>=', $WCAG_AA, 'secondary button text passes WCAG AA contrast' );
cmp_ok( _contrast( '#ffffff', $tokens{'color-accent'} ),
    '>=', $WCAG_AA, 'accent action text passes WCAG AA contrast' );
cmp_ok( _contrast( '#ffffff', $tokens{'color-danger'} ),
    '>=', $WCAG_AAA, 'danger state text passes WCAG AAA contrast' );
cmp_ok( _contrast( '#ffffff', $tokens{'color-success'} ),
    '>=', $WCAG_AA, 'success state text passes WCAG AA contrast' );

like( $css, qr/:focus-visible/msx, 'theme defines visible focus states' );
like( $css, qr/[.]skip-link:focus/msx,
    'theme keeps skip link keyboard-visible' );
like( $css, qr/prefers-reduced-motion/msx,
    'theme honors reduced motion preference' );
like(
    $css,
    qr/html\[data-theme="dark"\]/msx,
    'theme has dark-mode token readiness without auto-enabling it'
);
like(
    $css,
    qr/html\[data-theme="high_contrast"\]/msx,
    'theme has high-contrast token readiness without auto-enabling it'
);

for my $theme (qw(default dark high_contrast)) {
    ok(
        -e path( 'themes', $theme, 'tokens.css' ),
        "$theme theme token file exists"
    );
    _theme_tokens_match_registry( $registry, $theme );
    _theme_contrast_ok( $registry, $theme );
}
like(
    $css,
    qr/html\[data-direction="rtl"\]/msx,
    'theme exposes direction-aware CSS hooks for future RTL locales'
);
like( $css, qr/--font-ui-latin/msx,
    'theme centralizes Latin typography token' );
like( $css, qr/inset-inline-start/msx,
    'theme uses logical positioning for directional layout' );
like( $css, qr/padding-inline-start/msx,
    'theme uses logical list spacing for directional layout' );
unlike(
    $css,
qr/\b(?:left|right):|padding-left|padding-right|margin-left|margin-right|border-left|border-right/msx,
    'SSR theme avoids physical inline CSS properties'
);
like( $css, qr/[.]breadcrumbs/msx, 'theme styles breadcrumb navigation' );
like( $css, qr/[.]flash-stack/msx, 'theme styles flash message stack' );
like( $css, qr/[.]form-error-summary/msx,
    'theme styles accessible form error summaries' );
like( $css, qr/[.]field-error/msx, 'theme styles field-level error messages' );
like(
    $css,
    qr/\[aria-invalid="true"\]/msx,
    'theme gives invalid controls a non-color-only state'
);
like( $css, qr/[.]visually-hidden/msx,
    'theme exposes screen-reader-only utility for semantic labels' );
like( $css, qr/[.]ui-status-banner/msx,
    'theme styles shared status banner surfaces' );
like( $css, qr/[.]ui-admin-table/msx,
    'theme styles shared admin table surfaces' );
like(
    $css,
    qr/[.]ui-notification-surface/msx,
    'theme styles shared notification surfaces'
);
ok(
    index( $css, 'nav[aria-label$="pagination" i]' ) >= 0,
    'theme styles screen-reader-safe pagination navs'
);
like(
    $css,
    qr/\@media \s+ print/msx,
    'theme includes print-safe typography and shell reduction'
);

my $test = Test::Mojo->new('GPForum');

$test->get_ok('/gpforum-ssr.css');
$test->status_is($HTTP_OK);
$test->content_like(qr/--color-primary:\s*\#214237/msx);

$test->get_ok('/gpforum-mark.svg');
$test->status_is($HTTP_OK);
$test->content_like(qr/GPForum/msx);

$test->get_ok( '/login' => { 'Accept-Language' => 'it' } );
$test->status_is($HTTP_OK);
$test->element_exists(
'html[lang="it"][dir="ltr"][data-locale="it"][data-direction="ltr"][data-script="Latn"][data-theme="default"][data-color-scheme="light"]'
);
$test->element_exists('body.app-shell.typography-latin');
$test->element_exists('link[rel="stylesheet"][href="/gpforum-ssr.css"]');
$test->element_exists('a.skip-link[href="#content"]');
$test->element_exists('header.site-header nav[aria-label="Principale"]');
$test->element_exists('nav.breadcrumbs[aria-label="Percorso"]');
$test->text_is( 'nav.breadcrumbs [aria-current="page"]' => 'Accedi' );
$test->element_exists('footer.site-footer');
$test->text_is( 'h1' => 'Accesso' );
$test->content_like(qr/Nome [ ] utente [ ] o [ ] email/msx);
$test->element_exists('form.theme-form[action="/theme"]');
$test->element_exists('select[name="theme"] option[value="high_contrast"]');

$test->get_ok( '/login' => { Cookie => 'gpforum_theme=dark' } );
$test->status_is($HTTP_OK);
$test->element_exists('html[data-theme="dark"][data-color-scheme="dark"]');
$test->element_exists('meta[name="theme-color"][content="#111412"]');

$test->get_ok( '/login' => { Cookie => 'gpforum_theme=neon' } );
$test->status_is($HTTP_OK);
$test->element_exists('html[data-theme="default"][data-color-scheme="light"]');

done_testing();

sub _theme_tokens_match_registry {
    my ( $registry, $theme ) = @_;

    my %file_tokens =
      _css_color_tokens( path( 'themes', $theme, 'tokens.css' )->slurp );
    for my $token_name ( @{ $registry->token_names } ) {
        my $css_name = _css_token_name($token_name);
        is(
            $file_tokens{$css_name},
            $registry->token( $theme, $token_name ),
            "$theme $css_name token matches registry"
        );
    }

    return;
}

sub _theme_contrast_ok {
    my ( $registry, $theme ) = @_;

    my $tokens = $registry->tokens($theme);
    cmp_ok( _contrast( $tokens->{foreground}, $tokens->{background} ),
        '>=', $WCAG_AA, "$theme foreground/background passes WCAG AA" );
    cmp_ok( _contrast( $tokens->{muted}, $tokens->{background} ),
        '>=', $WCAG_AA, "$theme muted/background passes WCAG AA" );
    cmp_ok( _contrast( $tokens->{primary}, $tokens->{background} ),
        '>=', $WCAG_AA, "$theme primary/background passes WCAG AA" );
    cmp_ok( _contrast( $tokens->{text_on_primary}, $tokens->{primary} ),
        '>=', $WCAG_AA, "$theme primary action text passes WCAG AA" );
    cmp_ok( _contrast( $tokens->{text_on_accent}, $tokens->{accent} ),
        '>=', $WCAG_AA, "$theme accent action text passes WCAG AA" );
    cmp_ok( _contrast( $tokens->{danger}, $tokens->{surface_danger} ),
        '>=', $WCAG_AA, "$theme danger surface text passes WCAG AA" );
    cmp_ok( _contrast( $tokens->{success}, $tokens->{surface_success} ),
        '>=', $WCAG_AA, "$theme success surface text passes WCAG AA" );
    cmp_ok( _contrast( $tokens->{warning}, $tokens->{surface_warning} ),
        '>=', $WCAG_AA, "$theme warning surface text passes WCAG AA" );

    return;
}

sub _root_tokens {
    my ($stylesheet) = @_;

    my ($root_block) = $stylesheet =~ /:root \s* \{ (.*?) \n\}/msx;
    my %tokens = _css_color_tokens($root_block);

    return %tokens;
}

sub _css_color_tokens {
    my ($stylesheet) = @_;

    my %tokens = $stylesheet =~ /--([a-z0-9-]+): \s* (\#[0-9a-f]{6})/gimsx;

    return %tokens;
}

sub _css_token_name {
    my ($token_name) = @_;

    $token_name =~ s/_/-/gmsx;

    return 'color-' . $token_name;
}

sub _contrast {
    my ( $first, $second ) = @_;

    my $first_luminance  = _relative_luminance($first);
    my $second_luminance = _relative_luminance($second);
    my $lighter =
        $first_luminance > $second_luminance
      ? $first_luminance
      : $second_luminance;
    my $darker =
        $first_luminance > $second_luminance
      ? $second_luminance
      : $first_luminance;

    return ( $lighter + $RATIO_OFFSET ) / ( $darker + $RATIO_OFFSET );
}

sub _relative_luminance {
    my ($hex) = @_;

    $hex =~ s/\A\#//msx;
    my @channels = map { hex($_) / $CHANNEL_MAX } $hex =~ /(..)(..)(..)/msx;
    my @linear   = map { _linear_channel($_) } @channels;

    return $RED_WEIGHT * $linear[0] + $GREEN_WEIGHT * $linear[1] +
      $BLUE_WEIGHT * $linear[2];
}

sub _linear_channel {
    my ($channel) = @_;

    return $channel / $SRGB_LINEAR_DIVISOR
      if $channel <= $SRGB_LIMIT;

    return ( ( $channel + $SRGB_OFFSET ) / $SRGB_DIVISOR )**$SRGB_POWER;
}

1;
