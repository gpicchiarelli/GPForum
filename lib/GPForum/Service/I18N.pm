# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::I18N;

use strict;
use warnings;

use Const::Fast;
use GPForum::Service::I18N::Catalog;
use GPForum::Service::I18N::Formatter;
use GPForum::Service::I18N::Locale;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $FALLBACK_LOCALE => 'en';

has default_locale => sub { return $FALLBACK_LOCALE; };
has catalogs =>
  sub { return GPForum::Service::I18N::Catalog->default_catalogs; };
has missing_key_logger => undef;
has catalog            => sub {
    my ($self) = @_;

    return GPForum::Service::I18N::Catalog->new( catalogs => $self->catalogs, );
};
has locale_table => sub {
    my ($self) = @_;

    my %supported = map { $_ => 1 } @{ $self->catalog->locales };

    return GPForum::Service::I18N::Locale->new(
        default_locale => $self->default_locale,
        supported      => \%supported,
    );
};
has formats => sub {
    my ($self) = @_;

    return GPForum::Service::I18N::Formatter->new(
        locale_table => $self->locale_table, );
};

sub supported_locales ($self) {
    return $self->catalog->locales;
}

sub locale_registry ($self) {
    return $self->locale_table->registry;
}

sub negotiate ( $self, $accept_language ) {
    return $self->locale_table->negotiate($accept_language);
}

sub supported_locale ( $self, $locale ) {
    return $self->locale_table->supported_locale($locale);
}

sub translate ( $self, $locale, $key, $variables = undef ) {
    if ( !$variables ) {
        $variables = {};
    }

    my $message = $self->_plain_message( $locale, $key );
    if ( !defined $message ) {
        return $key;
    }

    return $self->catalog->interpolate( $message, $variables );
}

sub translate_count ( $self, $locale, $key, $count, $variables = undef ) {
    if ( !$variables ) {
        $variables = {};
    }
    $variables->{count} = $count;

    my $message = $self->_counted_message( $locale, $key, $count );
    if ( !defined $message ) {
        return $key;
    }

    return $self->catalog->interpolate( $message, $variables );
}

sub plural_category ( $self, $locale, $count ) {
    return $self->formats->plural_category( $locale, $count );
}

sub locale_metadata ( $self, $locale ) {
    return $self->locale_table->metadata($locale);
}

sub direction ( $self, $locale ) {
    return $self->locale_table->direction($locale);
}

sub format_date ( $self, $locale, $epoch, $zone = undef ) {
    return $self->formats->format_date( $locale, $epoch, $zone );
}

sub format_time ( $self, $locale, $epoch, $zone = undef ) {
    return $self->formats->format_time( $locale, $epoch, $zone );
}

sub format_datetime ( $self, $locale, $epoch, $zone = undef ) {
    return $self->formats->format_datetime( $locale, $epoch, $zone );
}

sub format_number ( $self, $locale, $number ) {
    return $self->formats->format_number( $locale, $number );
}

sub catalog_keys ( $self, $locale ) {
    return $self->catalog->keys_for($locale);
}

sub missing_catalog_keys ( $self, $locale ) {
    return $self->catalog->missing_keys($locale);
}

sub has_key ( $self, $locale, $key ) {
    return $self->catalog->has_key( $locale, $key );
}

sub _plain_message ( $self, $locale, $key ) {
    my $normalized = $self->supported_locale($locale) || q{};
    my $message    = $self->_usable_plain( $normalized, $key );
    if ( defined $message ) {
        return $message;
    }

    $self->_log_missing_key( $normalized || $FALLBACK_LOCALE, $key, 'missing' );
    my $undefined;
    return $undefined;
}

sub _usable_plain ( $self, $locale, $key ) {
    my $message = $self->catalog->message( $locale, $key );
    if ( _is_plain($message) ) {
        return $message;
    }

    return $self->_fallback_plain( $locale, $key );
}

sub _fallback_plain ( $self, $locale, $key ) {
    my $undefined;

    if ( $locale eq $FALLBACK_LOCALE ) {
        return $undefined;
    }

    $self->_log_missing_key( $locale, $key, 'fallback' );
    my $message = $self->catalog->message( $FALLBACK_LOCALE, $key );
    if ( _is_plain($message) ) {
        return $message;
    }

    return $undefined;
}

sub _counted_message ( $self, $locale, $key, $count ) {
    my $normalized = $self->supported_locale($locale) || q{};
    my $message    = $self->_usable_counted( $normalized, $key, $count );
    if ( defined $message ) {
        return $message;
    }

    $self->_log_missing_key( $normalized || $FALLBACK_LOCALE, $key, 'missing' );
    my $undefined;
    return $undefined;
}

sub _usable_counted ( $self, $locale, $key, $count ) {
    my $message = $self->_plural_for( $locale, $key, $count );
    if ( defined $message ) {
        return $message;
    }

    return $self->_fallback_counted( $locale, $key, $count );
}

sub _fallback_counted ( $self, $locale, $key, $count ) {
    if ( $locale eq $FALLBACK_LOCALE ) {
        my $undefined;
        return $undefined;
    }

    $self->_log_missing_key( $locale, $key, 'fallback' );
    return $self->_plural_for( $FALLBACK_LOCALE, $key, $count );
}

sub _plural_for ( $self, $locale, $key, $count ) {
    return $self->catalog->plural_form(
        $self->catalog->message( $locale, $key ),
        $self->plural_category( $locale, $count ),
    );
}

sub _is_plain ($message) {
    if ( !defined $message ) {
        return 0;
    }
    if ( ref $message ne q{} ) {
        return 0;
    }

    return 1;
}

sub _log_missing_key ( $self, $locale, $key, $reason ) {
    my $logger = $self->missing_key_logger;
    if ( !$logger ) {
        return;
    }

    $logger->(
        {
            key    => $key,
            locale => $locale,
            reason => $reason,
        }
    );

    return;
}

1;
