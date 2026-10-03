# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::I18N::Catalog;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use GPForum::Service::I18N::PoFile;
use List::Util qw(any);
use Mojo::Base -base, -signatures;
use Mojo::File qw(path);

our $VERSION = '0.001';

const my $FALLBACK_LOCALE => 'en';

# This module is lib/GPForum/Service/I18N/Catalog.pm in the checkout, four
# directories below the root that holds locale/. Resolved while the module
# loads, so a later chdir cannot move it.
const my $CHECKOUT_DEPTH   => 4;
const my $LOCALE_DIRECTORY => _locale_directory_of(__FILE__);

# A catalog is named after its locale: en.po, it.po, pt-br.po. ASCII only
# (/aa), so a lookalike letter cannot name a locale.
const my $CATALOG_FILE =>
  qr/\A ([[:lower:]]{2,3} (?:-[[:lower:][:digit:]]{2,8})*) [.]po \z/msxaa;

# The plural rule a catalog must declare, the one the formatter's categories
# serve: msgstr[0] is the form for a count of one and msgstr[1] for any
# other. Compared without spaces or the closing semicolon.
const my @PLURAL_RULES =>
  ( 'nplurals=2;plural=(n!=1)', 'nplurals=2;plural=n!=1' );
const my @PLURAL_CATEGORIES => qw(one other);

# Read once, when the module loads -- in Hypnotoad's manager, before it forks
# the workers -- and copied for each catalog, so none can change another's.
my $BUNDLED = load_catalogs( __PACKAGE__, $LOCALE_DIRECTORY );

has catalogs => sub { return default_catalogs(); };

sub default_catalogs {
    return _copy($BUNDLED);
}

sub locale_directory {
    return $LOCALE_DIRECTORY;
}

sub load_catalogs ( $, $directory ) {
    my $files = path($directory)->list->grep(qr/[.]po\z/msx);
    my %catalogs;
    for my $file ( $files->sort->each ) {
        my ($locale) = $file->basename =~ $CATALOG_FILE;
        croak "$file: a catalog is named after its locale code, in lower case"
          . ' (it.po, pt-br.po)'
          if !defined $locale;
        $catalogs{$locale} = _locale_messages( $file, $locale );
    }
    croak "$directory has no $FALLBACK_LOCALE.po, the catalog every locale"
      . ' falls back to'
      if !$catalogs{$FALLBACK_LOCALE};

    return \%catalogs;
}

sub locales ($self) {
    return [ sort keys %{ $self->catalogs } ];
}

sub keys_for ( $self, $locale ) {
    my $catalog = $self->_locale_catalog($locale);
    my @keys    = sort keys %{$catalog};

    return \@keys;
}

sub missing_keys ( $self, $locale ) {
    my %fallback = map       { $_ => 1 } @{ $self->keys_for($FALLBACK_LOCALE) };
    my %catalog  = map       { $_ => 1 } @{ $self->keys_for($locale) };
    my @missing  = sort grep { !$catalog{$_} } keys %fallback;

    return \@missing;
}

sub has_key ( $self, $locale, $key ) {
    if ( !exists $self->catalogs->{$locale} ) {
        return 0;
    }
    if ( exists $self->catalogs->{$locale}{$key} ) {
        return 1;
    }

    return 0;
}

sub message ( $self, $locale, $key ) {
    my $catalog = $self->_locale_catalog($locale);
    if ( !%{$catalog} ) {
        my $undefined;
        return $undefined;
    }

    return $catalog->{$key};
}

sub plural_form ( $, $message, $category ) {
    return _scalar_form( $message, $category );
}

sub interpolate ( $, $message, $variables ) {
    my $output = q{};
    my $rest   = $message;
    while (1) {
        my ( $prefix, $name, $suffix ) = _split_placeholder($rest);
        if ( !defined $name ) {
            last;
        }
        $output .= $prefix;
        $output .= _variable( $variables, $name );
        $rest = $suffix;
    }

    return $output . $rest;
}

sub _locale_catalog ( $self, $locale ) {
    if ( !defined $locale ) {
        return {};
    }
    if ( exists $self->catalogs->{$locale} ) {
        return $self->catalogs->{$locale};
    }

    return {};
}

sub _scalar_form ( $message, $category ) {
    if ( !defined $message ) {
        my $undefined;
        return $undefined;
    }
    if ( ref $message eq q{} ) {
        return $message;
    }

    return _hash_form( $message, $category );
}

sub _hash_form ( $message, $category ) {
    if ( ref $message ne 'HASH' ) {
        my $undefined;
        return $undefined;
    }
    if ( exists $message->{$category} ) {
        return $message->{$category};
    }

    return $message->{other};
}

sub _split_placeholder ($text) {
    if ( $text =~ /\A (.*?) [{] ([[:alnum:]_]+) [}] (.*) \z/msx ) {
        return ( $1, $2, $3 );
    }

    return;
}

sub _variable ( $variables, $name ) {
    if ( exists $variables->{$name} ) {
        return $variables->{$name};
    }

    return q{};
}

sub _locale_directory_of ($file) {
    my $directory = path($file)->to_abs->dirname;
    for ( 1 .. $CHECKOUT_DEPTH ) {
        $directory = $directory->dirname;
    }

    return $directory->child('locale')->to_string;
}

# One locale's messages: the key is the msgctxt, the text the msgstr, and a
# plural entry's msgstr[0] and msgstr[1] its one and other forms -- the shape
# the lookups below and GPForum::Service::I18N read.
sub _locale_messages ( $file, $locale ) {
    my $document = GPForum::Service::I18N::PoFile->read_file("$file");
    _check_header( $file, $locale, $document->{header} );

    my ( %messages, %line_of );
    for my $entry ( @{ $document->{entries} } ) {
        my $key = $entry->{context} // q{};
        croak "$file line $entry->{line}: a message needs its key as msgctxt"
          if $key eq q{};
        croak "$file line $entry->{line}: $key is already on line"
          . " $line_of{$key}"
          if exists $line_of{$key};
        $line_of{$key} = $entry->{line};

        if ( _translated($entry) ) {
            $messages{$key} = _message($entry);
        }
    }

    return \%messages;
}

sub _check_header ( $file, $locale, $header ) {
    my $language = $header->{Language} // q{};
    croak "$file: its header says Language: $language, not $locale"
      if lc( $language =~ tr/_/-/r ) ne $locale;

    my $declared = $header->{'Plural-Forms'} // q{};
    my $rule     = $declared =~ s/\s+//gmsxr =~ s/;\z//msxr;
    croak "$file: Plural-Forms '$declared' is not the rule the formatter"
      . ' serves, nplurals=2; plural=(n != 1);'
      if !any { $_ eq $rule } @PLURAL_RULES;

    return;
}

# As gettext reads a catalog: a fuzzy entry waits for a translator's review
# and an empty msgstr is untranslated, so neither is shown. Its key falls
# back to English, which GPForum::Service::I18N logs.
sub _translated ($entry) {
    if ( $entry->{flags}{fuzzy} ) {
        return 0;
    }

    return ( any { $_ eq q{} } @{ $entry->{strings} } ) ? 0 : 1;
}

sub _message ($entry) {
    if ( !defined $entry->{id_plural} ) {
        return $entry->{strings}[0];
    }

    # PoFile has held the forms to nplurals, and _check_header nplurals to 2.
    my %forms;
    @forms{@PLURAL_CATEGORIES} = @{ $entry->{strings} };

    return \%forms;
}

sub _copy ($catalogs) {
    my %copy;
    for my $locale ( keys %{$catalogs} ) {
        my $messages = $catalogs->{$locale};
        $copy{$locale} =
          { map { $_ => _copy_message( $messages->{$_} ) } keys %{$messages} };
    }

    return \%copy;
}

sub _copy_message ($message) {
    return ref $message eq 'HASH' ? { %{$message} } : $message;
}

1;

__END__

=head1 NAME

GPForum::Service::I18N::Catalog - Presentation string catalogs.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $catalog = GPForum::Service::I18N::Catalog->new;
    my $text    = $catalog->message( 'it', 'nav.categories' );

    my $catalogs =
      GPForum::Service::I18N::Catalog->load_catalogs('/tmp/locale');

=head1 DESCRIPTION

Holds the presentation catalogs, with lookup, plural-form selection and
C<{variable}> interpolation. Locale negotiation and date or number
formatting stay on dedicated I18N helpers, and
L<GPForum::Service::I18N> remains the public facade.

The messages are GNU gettext PO files in the checkout's C<locale/>
directory, one per locale and named after it (C<en.po>, C<it.po>), which
translators edit with gettext's tools or any PO editor. In each, an entry's
C<msgctxt> is the key the code asks for, C<msgid> the English text and
C<msgstr> the locale's; a plural entry carries C<msgid_plural> and
C<msgstr[0]> and C<msgstr[1]>, read as the C<one> and C<other> forms.
They are read once, when the module loads, by
L<GPForum::Service::I18N::PoFile>, into a hash of locale to key to message:
a string, or a hash reference of C<one> and C<other> for a plural message.
A fuzzy entry or an empty C<msgstr> is untranslated, as for gettext, and is
left out, so the lookup falls back to English and is logged.
F<docs/i18n.md> describes the translators' workflow.

=head1 SUBROUTINES/METHODS

=head2 default_catalogs

Returns a copy of the catalogs read from C<locale/> when the module loaded,
as a hash reference of locale to key to message.

=head2 locale_directory

Returns the absolute path of the checkout's C<locale/> directory, where the
bundled catalogs are.

=head2 load_catalogs

Takes a directory. Returns the catalogs its C<*.po> files hold, in the shape
L</default_catalogs> returns, and croaks when one is malformed (see
L</DIAGNOSTICS>). Files that do not end in C<.po>, a template among them,
are not read, nor are hidden ones, such as an editor's C<.#it.po> lock.

=head2 locales

Returns the sorted catalog locale ids.

=head2 keys_for

Returns sorted keys for one locale.

=head2 missing_keys

Returns English keys absent from the requested locale.

=head2 has_key

True when the locale catalog contains the key.

=head2 message

Returns the catalog value for a locale and key.

=head2 plural_form

Selects a scalar string or a C<one>/C<other> hash entry.

=head2 interpolate

Replaces C<{name}> placeholders from a variable hash.

=head1 DIAGNOSTICS

Missing keys return undef from C<message>. Interpolation of unknown names
inserts an empty string.

Reading a catalog croaks, naming the file and, where there is one, the
line, when the PO file is malformed
(L<GPForum::Service::I18N::PoFile/DIAGNOSTICS>) and when:

=over 4

=item C<FILE: a catalog is named after its locale code, in lower case>

=item C<DIRECTORY has no en.po, the catalog every locale falls back to>

=item C<FILE: its header says Language: X, not LOCALE>

=item C<FILE: Plural-Forms 'RULE' is not the rule the formatter serves>

=item C<FILE line N: a message needs its key as msgctxt>

=item C<FILE line N: KEY is already on line M>

=back

The bundled catalogs are read when the module loads, so a malformed one
stops the application at startup rather than serving keys.

=head1 CONFIGURATION AND ENVIRONMENT

The bundled catalogs are the C<locale/*.po> files of the checkout this
module is in. Runtime overrides go through the C<catalogs> attribute here
or on L<GPForum::Service::I18N>.

=head1 DEPENDENCIES

L<GPForum::Service::I18N::PoFile>, L<Const::Fast>, L<List::Util>,
L<Mojo::Base>, L<Mojo::File>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Plural selection understands C<one> and C<other> only, so every catalog
must declare C<Plural-Forms: nplurals=2; plural=(n != 1);>. A language
with another rule (French counts zero as singular, Polish has three forms)
needs the formatter's categories first.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
