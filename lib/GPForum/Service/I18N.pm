# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::I18N;

use Const::Fast;
use GPForum::Service::I18N::Catalog;
use GPForum::Service::I18N::Formatter;
use GPForum::Service::I18N::Locale;
use Mojo::Base -base, -signatures;
use v5.40;

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
    return undef;
}

sub _usable_plain ( $self, $locale, $key ) {
    my $message = $self->catalog->message( $locale, $key );
    if ( _is_plain($message) ) {
        return $message;
    }

    return $self->_fallback_plain( $locale, $key );
}

sub _fallback_plain ( $self, $locale, $key ) {
    if ( $locale eq $FALLBACK_LOCALE ) {
        return undef;
    }

    $self->_log_missing_key( $locale, $key, 'fallback' );
    my $message = $self->catalog->message( $FALLBACK_LOCALE, $key );
    if ( _is_plain($message) ) {
        return $message;
    }

    return undef;
}

sub _counted_message ( $self, $locale, $key, $count ) {
    my $normalized = $self->supported_locale($locale) || q{};
    my $message    = $self->_usable_counted( $normalized, $key, $count );
    if ( defined $message ) {
        return $message;
    }

    $self->_log_missing_key( $normalized || $FALLBACK_LOCALE, $key, 'missing' );
    return undef;
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
        return undef;
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

__END__

=head1 NAME

GPForum::Service::I18N - Translation, locale negotiation and formatting behind one object.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $i18n = GPForum::Service::I18N->new( default_locale => 'it' );

    my $locale = $i18n->negotiate('it-IT,it;q=0.9,en;q=0.8');
    my $label  = $i18n->translate( $locale, 'nav.categories' );
    my $unread =
      $i18n->translate_count( $locale, 'notifications.unread_count', $count );
    my $when = $i18n->format_datetime( $locale, $epoch, 'Europe/Rome' );

=head1 DESCRIPTION

The facade that controllers, templates and the notification renderer ask
for text. It wires three helpers together:
L<GPForum::Service::I18N::Catalog> holds the messages (English and Italian,
read from the gettext PO files in C<locale/>, unless C<catalogs> says
otherwise), L<GPForum::Service::I18N::Locale> negotiates and describes
locales, and L<GPForum::Service::I18N::Formatter> formats dates, numbers
and plural categories. The supported locales are the ones the catalogs
carry: one per PO file.

A message the requested locale lacks is taken from English; when English
lacks it too, the key itself is returned, so a page shows the key rather
than failing. A locale lacks a message its PO file leaves out, leaves
untranslated (an empty C<msgstr>) or marks fuzzy, as gettext would not show
those either. When C<missing_key_logger> is set, it is called with
C<< { key, locale, reason } >> for each lookup that falls back to English
(C<< reason => 'fallback' >>) and again for a key found nowhere
(C<< reason => 'missing' >>). For C<translate>, a plural message (a hash of
forms) counts as missing; C<translate_count> picks its form.

=head1 SUBROUTINES/METHODS

=head2 supported_locales

Returns an array reference of the catalogs' locale codes, sorted.

=head2 locale_registry

Returns a hash reference of locale code to a copy of that locale's metadata
(names, direction, date, time and number patterns), for the supported
locales only.

=head2 negotiate

Takes an C<Accept-Language> header value. Returns the first supported
locale in quality order, a regional tag matching on its base language
(C<it-IT> gives C<it>). C<*>, an empty header or no match gives the default
locale, or C<en> when the default is not supported.

=head2 supported_locale

Takes a locale tag. Returns the supported locale it names, exactly or by its
base language, after trimming, lower-casing and turning C<_> into C<->;
undef when there is none.

=head2 translate

Takes a locale, a key and an optional hash reference of variables. Returns
the message with each C<{name}> placeholder replaced by its variable (an
unknown placeholder becomes empty), falling back to English and then to the
key as described above.

=head2 translate_count

Takes a locale, a key, a count and an optional hash reference of variables;
the count is stored in the variables as C<count>, in the hash passed when
there is one. Returns the message's plural form for the count (C<one> or
C<other>, then C<other> when that form is absent; a plain string message is
used as it is), interpolated, with the same fallbacks as C<translate>.

=head2 plural_category

Takes a locale and a count. Returns C<one> for a count of 1 and C<other>
otherwise, whatever the locale.

=head2 locale_metadata

Takes a locale. Returns a copy of its metadata hash, or the default
locale's when it is not supported.

=head2 direction

Takes a locale. Returns its text direction from the metadata (C<ltr> for
both bundled locales).

=head2 format_date

Takes a locale, an epoch or ISO 8601 timestamp, and an optional IANA time
zone. Returns the date in the locale's date pattern, in UTC without a zone
and converted to the zone with one (an unknown zone name is UTC). Returns
nothing for a missing or unparseable timestamp.

=head2 format_time

As C<format_date>, with the locale's time pattern; with a zone, the zone's
abbreviation is appended.

=head2 format_datetime

As C<format_time>, with the locale's date and time pattern.

=head2 format_number

Takes a locale and a number. Returns it with two decimals and the locale's
thousands and decimal marks; anything that is not a plain decimal number
formats as zero.

=head2 catalog_keys

Takes a locale. Returns an array reference of its catalog's keys, sorted;
empty for an unknown locale.

=head2 missing_catalog_keys

Takes a locale. Returns an array reference of the English keys that
locale's catalog lacks, sorted.

=head2 has_key

Takes a locale and a key. Returns 1 when that locale's catalog has the key
and 0 otherwise, without falling back.

=head1 DIAGNOSTICS

None. A missing message is returned as its key and reported to
C<missing_key_logger>, never thrown.

=head1 CONFIGURATION AND ENVIRONMENT

C<default_locale> (default C<en>), which the bootstrap sets from the
configuration's C<default_locale>; C<catalogs>, to replace the bundled
catalogs (L<GPForum::Service::I18N::Catalog/load_catalogs> reads another
directory of PO files); and C<missing_key_logger>, a code reference.

=head1 DEPENDENCIES

L<GPForum::Service::I18N::Catalog>, L<GPForum::Service::I18N::Formatter>,
L<GPForum::Service::I18N::Locale>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
