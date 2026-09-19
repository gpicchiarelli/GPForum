package GPForum::Service::I18N;

use strict;
use warnings;

use Const::Fast;
use GPForum::Service::I18N::Catalog;
use GPForum::Service::I18N::Formatter;
use GPForum::Service::I18N::Locale;
use Mojo::Base -base;

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

sub supported_locales {
    my ($self) = @_;

    return $self->catalog->locales;
}

sub locale_registry {
    my ($self) = @_;

    return $self->locale_table->registry;
}

sub negotiate {
    my ( $self, $accept_language ) = @_;

    return $self->locale_table->negotiate($accept_language);
}

sub supported_locale {
    my ( $self, $locale ) = @_;

    return $self->locale_table->supported_locale($locale);
}

sub translate {
    my ( $self, $locale, $key, $variables ) = @_;

    if ( !$variables ) {
        $variables = {};
    }

    my $message = $self->_plain_message( $locale, $key );
    if ( !defined $message ) {
        return $key;
    }

    return $self->catalog->interpolate( $message, $variables );
}

sub translate_count {
    my ( $self, $locale, $key, $count, $variables ) = @_;

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

sub plural_category {
    my ( $self, $locale, $count ) = @_;

    return $self->formats->plural_category( $locale, $count );
}

sub locale_metadata {
    my ( $self, $locale ) = @_;

    return $self->locale_table->metadata($locale);
}

sub direction {
    my ( $self, $locale ) = @_;

    return $self->locale_table->direction($locale);
}

sub format_date {
    my ( $self, $locale, $epoch ) = @_;

    return $self->formats->format_date( $locale, $epoch );
}

sub format_time {
    my ( $self, $locale, $epoch ) = @_;

    return $self->formats->format_time( $locale, $epoch );
}

sub format_datetime {
    my ( $self, $locale, $epoch ) = @_;

    return $self->formats->format_datetime( $locale, $epoch );
}

sub format_number {
    my ( $self, $locale, $number ) = @_;

    return $self->formats->format_number( $locale, $number );
}

sub catalog_keys {
    my ( $self, $locale ) = @_;

    return $self->catalog->keys_for($locale);
}

sub missing_catalog_keys {
    my ( $self, $locale ) = @_;

    return $self->catalog->missing_keys($locale);
}

sub has_key {
    my ( $self, $locale, $key ) = @_;

    return $self->catalog->has_key( $locale, $key );
}

sub _plain_message {
    my ( $self, $locale, $key ) = @_;

    my $normalized = $self->supported_locale($locale) || q{};
    my $message    = $self->_usable_plain( $normalized, $key );
    if ( defined $message ) {
        return $message;
    }

    $self->_log_missing_key( $normalized || $FALLBACK_LOCALE, $key, 'missing' );
    return;
}

sub _usable_plain {
    my ( $self, $locale, $key ) = @_;

    my $message = $self->catalog->message( $locale, $key );
    if ( _is_plain($message) ) {
        return $message;
    }

    return $self->_fallback_plain( $locale, $key );
}

sub _fallback_plain {
    my ( $self, $locale, $key ) = @_;

    if ( $locale eq $FALLBACK_LOCALE ) {
        return;
    }

    $self->_log_missing_key( $locale, $key, 'fallback' );
    my $message = $self->catalog->message( $FALLBACK_LOCALE, $key );
    if ( _is_plain($message) ) {
        return $message;
    }

    return;
}

sub _counted_message {
    my ( $self, $locale, $key, $count ) = @_;

    my $normalized = $self->supported_locale($locale) || q{};
    my $message    = $self->_usable_counted( $normalized, $key, $count );
    if ( defined $message ) {
        return $message;
    }

    $self->_log_missing_key( $normalized || $FALLBACK_LOCALE, $key, 'missing' );
    return;
}

sub _usable_counted {
    my ( $self, $locale, $key, $count ) = @_;

    my $message = $self->_plural_for( $locale, $key, $count );
    if ( defined $message ) {
        return $message;
    }

    return $self->_fallback_counted( $locale, $key, $count );
}

sub _fallback_counted {
    my ( $self, $locale, $key, $count ) = @_;

    if ( $locale eq $FALLBACK_LOCALE ) {
        return;
    }

    $self->_log_missing_key( $locale, $key, 'fallback' );
    return $self->_plural_for( $FALLBACK_LOCALE, $key, $count );
}

sub _plural_for {
    my ( $self, $locale, $key, $count ) = @_;

    return $self->catalog->plural_form(
        $self->catalog->message( $locale, $key ),
        $self->plural_category( $locale, $count ),
    );
}

sub _is_plain {
    my ($message) = @_;

    if ( !defined $message ) {
        return 0;
    }
    if ( ref $message ne q{} ) {
        return 0;
    }

    return 1;
}

sub _log_missing_key {
    my ( $self, $locale, $key, $reason ) = @_;

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
