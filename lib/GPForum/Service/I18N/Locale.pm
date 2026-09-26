# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::I18N::Locale;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $FALLBACK_LOCALE => 'en';
const my $DEFAULT_QUALITY => 1;
const my $ZERO_QUALITY    => 0;
const my $WILDCARD        => q{*};
const my $QUALITY_DESC    => -1;

has default_locale => sub { return $FALLBACK_LOCALE; };
has supported      => sub { return { $FALLBACK_LOCALE => 1 }; };

sub negotiate ( $self, $accept_language ) {
    my $default_locale = $self->safe_default;
    for my $range ( $self->language_ranges($accept_language) ) {
        my $matched = $self->_negotiated_locale( $range, $default_locale );
        if ( defined $matched ) {
            return $matched;
        }
    }

    return $default_locale;
}

sub supported_locale ( $self, $locale ) {
    return $self->matching( $self->normalize($locale) );
}

sub matching ( $self, $tag ) {
    if ( !$self->has_text($tag) ) {
        my $undefined;
        return $undefined;
    }
    if ( $self->supported->{$tag} ) {
        return $tag;
    }

    return $self->_base_match($tag);
}

sub language_ranges ( $self, $accept_language ) {

    # A bare `return` and not `return $undefined`: this is called in list
    # context by negotiate, where returning a scalar yields a one-element list
    # holding undef rather than an empty one. That made every request without
    # an Accept-Language header — curl, health checks, most API clients — loop
    # once over an undefined range and warn.
    if ( !$self->has_text($accept_language) ) {
        return;
    }

    return $self->_ordered_ranges($accept_language);
}

sub registry ($self) {
    my $all = $self->_metadata_registry;
    my %out;
    for my $locale ( keys %{$all} ) {
        if ( $self->supported->{$locale} ) {
            $out{$locale} = { %{ $all->{$locale} } };
        }
    }

    return \%out;
}

sub metadata ( $self, $locale ) {
    my $safe = $self->supported_locale($locale);
    if ( !$safe ) {
        $safe = $self->safe_default;
    }

    return { %{ $self->_entry($safe) } };
}

sub direction ( $self, $locale ) {
    return $self->metadata($locale)->{direction};
}

sub safe_default ($self) {
    my $locale = $self->supported_locale( $self->default_locale );
    if ($locale) {
        return $locale;
    }

    return $FALLBACK_LOCALE;
}

sub normalize ( $self, $tag ) {
    if ( !defined $tag ) {
        return q{};
    }

    return $self->_normalized( $self->trim($tag) );
}

sub trim ( $, $value ) {
    if ( !defined $value ) {
        return q{};
    }

    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

sub has_text ( $, $value ) {
    if ( !defined $value ) {
        return 0;
    }

    return length $value ? 1 : 0;
}

sub _negotiated_locale ( $self, $range, $default_locale ) {
    if ( $range->{tag} eq $WILDCARD ) {
        return $default_locale;
    }

    return $self->matching( $range->{tag} );
}

sub _ordered_ranges ( $self, $accept_language ) {
    my $position = 0;
    my @ranges;
    for my $part ( split /,/msx, $accept_language ) {
        $position++;
        my $range = $self->_range_from_part( $part, $position );
        if ($range) {
            push @ranges, $range;
        }
    }

    return $self->_sort_ranges( \@ranges );
}

sub _range_from_part ( $self, $part, $position ) {
    my ( $tag, @parameters ) = map { $self->trim($_) } split /;/msx, $part;
    my $normalized = $self->normalize($tag);
    if ( !$self->has_text($normalized) ) {
        my $undefined;
        return $undefined;
    }

    return $self->_quality_range( $normalized, \@parameters, $position );
}

sub _quality_range ( $self, $tag, $parameters, $position ) {
    my $quality = $self->_quality($parameters);
    if ( $quality <= $ZERO_QUALITY ) {
        my $undefined;
        return $undefined;
    }

    return {
        position => $position,
        quality  => $quality,
        tag      => $tag,
    };
}

sub _quality ( $self, $parameters ) {
    for my $parameter ( @{$parameters} ) {
        my $quality = $self->_quality_value($parameter);
        if ( defined $quality ) {
            return $quality;
        }
    }

    return $DEFAULT_QUALITY;
}

sub _quality_value ( $, $parameter ) {
    if ( $parameter =~ /\A q=([[:digit:]] (?:[.][[:digit:]]+)?) \z/imsx ) {
        return $1 + 0;
    }

    my $undefined;
    return $undefined;
}

sub _sort_ranges ( $, $ranges ) {
    my @sorted = sort {
        ( $QUALITY_DESC * $a->{quality} ) <=> ( $QUALITY_DESC * $b->{quality} )
          || $a->{position} <=> $b->{position}
    } @{$ranges};

    return @sorted;
}

sub _base_match ( $self, $tag ) {
    my ($base_tag) = split /-/msx, $tag;
    if ( $self->supported->{$base_tag} ) {
        return $base_tag;
    }

    my $undefined;
    return $undefined;
}

sub _entry ( $self, $locale ) {
    my $registry = $self->_metadata_registry;
    if ( exists $registry->{$locale} ) {
        return $registry->{$locale};
    }

    return $registry->{$FALLBACK_LOCALE};
}

sub _normalized ( $self, $tag ) {
    $tag = lc $tag;
    $tag =~ s/_/-/gmsx;
    if ( $tag eq $WILDCARD ) {
        return $WILDCARD;
    }
    if ( $self->_is_locale_tag($tag) ) {
        return $tag;
    }

    return q{};
}

sub _is_locale_tag ( $, $tag ) {
    if ( $tag =~ /\A [[:lower:]]{2,8} (?: - [[:lower:][:digit:]]{1,8})* \z/msx )
    {
        return 1;
    }

    return 0;
}

sub _metadata_registry {
    return {
        en => {
            date_format       => '%Y-%m-%d',
            datetime_format   => '%Y-%m-%d %H:%M',
            decimal_mark      => q{.},
            direction         => 'ltr',
            font_family_token => 'ui-latin',
            name              => 'English',
            native_name       => 'English',
            number_system     => 'latn',
            script            => 'Latn',
            thousand_mark     => q{,},
            time_format       => '%H:%M',
            typography_class  => 'typography-latin',
        },
        it => {
            date_format       => '%d/%m/%Y',
            datetime_format   => '%d/%m/%Y %H:%M',
            decimal_mark      => q{,},
            direction         => 'ltr',
            font_family_token => 'ui-latin',
            name              => 'Italian',
            native_name       => 'Italiano',
            number_system     => 'latn',
            script            => 'Latn',
            thousand_mark     => q{.},
            time_format       => '%H:%M',
            typography_class  => 'typography-latin',
        },
    };
}

1;

__END__

=head1 NAME

GPForum::Service::I18N::Locale - Locale negotiation and metadata.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $locale = $table->negotiate('it-IT,it;q=0.9,en;q=0.2');

=head1 DESCRIPTION

Owns Accept-Language negotiation, supported-locale matching, direction, and
locale metadata. Catalog lookup and number or date formatting stay on
dedicated I18N helpers. L<GPForum::Service::I18N> remains the public facade.

=head1 SUBROUTINES/METHODS

=head2 negotiate

Chooses a supported locale from an Accept-Language header.

=head2 supported_locale

Returns a supported locale id or undef.

=head2 matching

Matches a normalized tag or its base language.

=head2 language_ranges

Parses Accept-Language into quality-ordered ranges.

=head2 registry

Returns metadata for supported locales only.

=head2 metadata

Returns metadata for a locale, falling back to the safe default.

=head2 direction

Returns ltr or rtl for a locale.

=head2 safe_default

Returns the configured default when supported, otherwise English.

=head2 normalize

Lowercases and hyphenates a locale tag.

=head2 trim

Strips surrounding whitespace.

=head2 has_text

True when the value is defined and non-empty.

=head1 DIAGNOSTICS

Unknown or empty tags yield the safe default during negotiation.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a C<supported> hash of locale ids. Quality values come from
Accept-Language.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Quality parsing accepts a broader digit form than the original 0-or-1 prefix.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
