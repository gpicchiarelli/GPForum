# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Theme::Registry;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $FALLBACK_THEME => 'default';
const my @THEME_NAMES    => qw(default dark high_contrast);
const my @TOKEN_NAMES => qw(
  background foreground muted surface surface_alt primary secondary accent
  border danger success focus_ring info warning surface_warning surface_danger
  surface_success text_on_primary text_on_accent text_on_danger text_on_success
  text_on_warning
);

has configured_default_theme => sub { return $FALLBACK_THEME; };

sub default_theme ($self) {
    return $self->safe_theme_name( $self->configured_default_theme );
}

sub supported_themes {
    return [@THEME_NAMES];
}

sub token_names {
    return [@TOKEN_NAMES];
}

sub supported ( $self, $name ) {
    return 0 if !defined $name || !length $name;

    my %supported = map { $_ => 1 } @{ $self->supported_themes };
    return $supported{$name} ? 1 : 0;
}

sub safe_theme_name ( $self, $name ) {
    return $self->supported($name) ? $name : $FALLBACK_THEME;
}

sub theme ( $self, $name ) {
    my $theme  = _theme_contracts()->{ $self->safe_theme_name($name) };
    my %tokens = %{ $theme->{tokens} };

    return { %{$theme}, %tokens, tokens => \%tokens };
}

sub tokens ( $self, $name ) {
    return { %{ $self->theme($name)->{tokens} } };
}

sub token ( $self, $theme_name, $token_name ) {
    return $self->tokens($theme_name)->{$token_name};
}

sub theme_color ( $self, $name ) {
    return $self->theme($name)->{theme_color};
}

sub color_scheme ( $self, $name ) {
    return $self->theme($name)->{color_scheme};
}

sub theme_options ( $self, $current_theme ) {
    my $safe_current = $self->safe_theme_name($current_theme);
    return [
        map {
            my $theme = $self->theme($_);
            {
                current      => $_ eq $safe_current ? 1 : 0,
                label_key    => $theme->{label_key},
                name         => $_,
                color_scheme => $theme->{color_scheme},
            }
        } @{ $self->supported_themes }
    ];
}

sub css_variables ( $self, $name ) {
    my $tokens = $self->tokens($name);
    return [ map { [ _css_token_name($_), $tokens->{$_} ] }
          @{ $self->token_names } ];
}

sub _css_token_name ($name) {
    $name =~ s/_/-/gmsx;

    return 'color-' . $name;
}

sub _theme_contracts {
    return {
        default => _contract(
            'default',
            'theme.default',
            'light',
            '#f8f6ef',
            {
                background      => '#f8f6ef',
                foreground      => '#111412',
                muted           => '#33423a',
                surface         => '#ffffff',
                surface_alt     => '#eef3f0',
                primary         => '#214237',
                secondary       => '#3f5f72',
                accent          => '#a6532f',
                border          => '#c7d1c8',
                danger          => '#9d2424',
                success         => '#236b45',
                focus_ring      => '#a6532f',
                info            => '#3f5f72',
                warning         => '#7b4c00',
                surface_warning => '#fff7df',
                surface_danger  => '#fff4f2',
                surface_success => '#eef8f1',
                text_on_primary => '#ffffff',
                text_on_accent  => '#ffffff',
                text_on_danger  => '#ffffff',
                text_on_success => '#ffffff',
                text_on_warning => '#111412',
            }
        ),
        dark => _contract(
            'dark',
            'theme.dark',
            'dark',
            '#111412',
            {
                background      => '#111412',
                foreground      => '#f8f6ef',
                muted           => '#d7d0c0',
                surface         => '#17211d',
                surface_alt     => '#1f3029',
                primary         => '#c9835a',
                secondary       => '#9bb6c8',
                accent          => '#f0ad7d',
                border          => '#5c7568',
                danger          => '#ffb4a8',
                success         => '#8fd6a3',
                focus_ring      => '#f0ad7d',
                info            => '#9bb6c8',
                warning         => '#ffd27a',
                surface_warning => '#342500',
                surface_danger  => '#3a1717',
                surface_success => '#15331f',
                text_on_primary => '#111412',
                text_on_accent  => '#111412',
                text_on_danger  => '#111412',
                text_on_success => '#111412',
                text_on_warning => '#111412',
            }
        ),
        high_contrast => _contract(
            'high_contrast',
            'theme.high_contrast',
            'light',
            '#ffffff',
            {
                background      => '#ffffff',
                foreground      => '#000000',
                muted           => '#101010',
                surface         => '#ffffff',
                surface_alt     => '#f2f2f2',
                primary         => '#003f2d',
                secondary       => '#00324d',
                accent          => '#7a2a00',
                border          => '#000000',
                danger          => '#8b0000',
                success         => '#005c2f',
                focus_ring      => '#ffbf00',
                info            => '#00324d',
                warning         => '#5a3a00',
                surface_warning => '#fff8cc',
                surface_danger  => '#fff0f0',
                surface_success => '#ecfff3',
                text_on_primary => '#ffffff',
                text_on_accent  => '#ffffff',
                text_on_danger  => '#ffffff',
                text_on_success => '#ffffff',
                text_on_warning => '#000000',
            }
        ),
    };
}

sub _contract ( $name, $label_key, $color_scheme, $theme_color, $tokens ) {
    return {
        color_scheme => $color_scheme,
        label_key    => $label_key,
        name         => $name,
        theme_color  => $theme_color,
        tokens       => $tokens,
    };
}

1;
