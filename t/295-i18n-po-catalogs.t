# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;
use utf8;

use Const::Fast;
use File::Spec;
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::Service::I18N;
use GPForum::Service::I18N::Catalog;
use GPForum::Service::I18N::PoFile;

our $VERSION = '0.001';

# Quality program 9.2: the translations are gettext PO files, one per
# locale, that a translator's tools can open -- msgctxt the key, msgid the
# English, msgstr the locale's text -- and these are the checks a reviewer
# would otherwise make by eye.
const my $FALLBACK_LOCALE => 'en';
const my %HEADER => (
    'Project-Id-Version'        => 'GPForum',
    'MIME-Version'              => '1.0',
    'Content-Type'              => 'text/plain; charset=UTF-8',
    'Content-Transfer-Encoding' => '8bit',
    'Plural-Forms'              => 'nplurals=2; plural=(n != 1);',
);

# The translator's comment that says a message is meant to read as the
# English does ("Admin", "Email"), so it is not taken for one left
# untranslated.
const my $SAME_AS_ENGLISH => qr/\A Same [ ] as [ ] English [.]? \z/imsx;
const my $PLACEHOLDER     => qr/[{] ([[:alnum:]_]+) [}]/msx;
const my $SEVERAL         => 3;

my $directory = GPForum::Service::I18N::Catalog->locale_directory;
is(
    $directory,
    path('locale')->to_abs->to_string,
    q{the catalogs are the checkout's locale/ directory}
);

my $files   = path($directory)->list->grep(qr/[.]po\z/msx);
my @locales = map { $_->basename('.po') } $files->sort->each;
is_deeply( \@locales, [qw(en it)],
    'one PO file per locale, English and Italian' );

my %documents = map {
    $_ => GPForum::Service::I18N::PoFile->read_file(
        path( $directory, "$_.po" )->to_string )
} @locales;
my %entries = map { $_ => _entries_by_key( $documents{$_} ) } @locales;

# The gate: the catalog is what the PO files hold, and nothing else.
is_deeply(
    GPForum::Service::I18N::Catalog->default_catalogs,
    GPForum::Service::I18N::Catalog->load_catalogs($directory),
    'the catalogs are read from the PO files'
);
is_deeply( _keys_in_module( $entries{$FALLBACK_LOCALE} ),
    [], 'and no message is left in the module' );

for my $locale (@locales) {
    is_deeply( _header_problems( $locale, $documents{$locale}{header} ),
        [], "$locale.po has the header gettext expects" );
    is_deeply( _malformed_entries( $documents{$locale} ),
        [], "$locale.po gives every message one key, once" );
    is_deeply( _untranslated_entries( $documents{$locale} ),
        [], "$locale.po translates every message: none empty or fuzzy" );
}

for my $locale ( grep { $_ ne $FALLBACK_LOCALE } @locales ) {
    is_deeply(
        _key_differences( $entries{$FALLBACK_LOCALE}, $entries{$locale} ),
        [], "$locale.po has every key en.po has, and no other" );
    is_deeply( _stale_sources( $entries{$FALLBACK_LOCALE}, $entries{$locale} ),
        [], "$locale.po translates the current English of every message" );
    is_deeply( _unmarked_copies( $entries{$locale} ),
        [],
        "$locale.po copies the English only where a comment says it should" );
}

is_deeply( _english_differences( $entries{$FALLBACK_LOCALE} ),
    [], 'en.po shows English readers its msgid, the source text itself' );

for my $locale (@locales) {
    is_deeply(
        _placeholder_differences(
            $entries{$FALLBACK_LOCALE},
            $entries{$locale}
        ),
        [],
        "$locale.po keeps every {placeholder} of the English"
    );
    is_deeply( _format_flag_problems( $entries{$locale} ),
        [], "$locale.po flags the messages with placeholders for its tools" );
}

{
    my @pluralised = _pluralised_keys();
    cmp_ok( scalar @pluralised,
        q{>=}, $SEVERAL, 'the code pluralises some messages' );
    my %plural = map { $_ => 1 }
      grep { defined $entries{$FALLBACK_LOCALE}{$_}{id_plural} }
      keys %{ $entries{$FALLBACK_LOCALE} };
    is_deeply(
        [ sort keys %plural ],
        [ sort @pluralised ],
        'a message is plural exactly where the code counts it'
    );

    my $i18n = GPForum::Service::I18N->new;
    for my $locale (@locales) {
        is_deeply( _plural_problems( $i18n, $locale, $entries{$locale} ),
            [], "$locale: msgstr[0] is said of one, msgstr[1] of several" );
    }
    is( $i18n->translate_count( 'en', 'common.time_days_ago', 1 ),
        'a day ago', 'an English count of one reads the singular' );
    is(
        $i18n->translate_count( 'en', 'common.time_days_ago', $SEVERAL ),
        "$SEVERAL days ago",
        'and any other count the plural'
    );
    is( $i18n->translate_count( 'it', 'common.time_hours_ago', 1 ),
        'un’ora fa', 'an Italian count of one reads the singular' );
    is(
        $i18n->translate_count( 'it', 'admin.search_pending', 0 ),
        '0 eventi in attesa',
        'and zero reads the plural, as in English'
    );
}

SKIP: {
    my $msgfmt = _which('msgfmt');
    if ( !$msgfmt ) {
        skip 'gettext tools are not installed', scalar @locales;
    }

    my $output =
      path( tempdir( CLEANUP => 1 ) )->child('catalog.mo')->to_string;
    for my $locale (@locales) {
        my $file = path( $directory, "$locale.po" )->to_string;
        is( system( $msgfmt, '--check', "--output-file=$output", $file ),
            0, "msgfmt --check accepts $locale.po" );
    }
}

done_testing();

sub _entries_by_key {
    my ($document) = @_;

    return { map { ( $_->{context} // q{} ) => $_ } @{ $document->{entries} } };
}

sub _forms {
    my ($entry) = @_;

    return @{ $entry->{strings} };
}

sub _sources {
    my ($entry) = @_;

    return grep { defined } $entry->{id}, $entry->{id_plural};
}

# A message's forms, or its sources, as one string to compare.
sub _joined {
    my (@texts) = @_;

    return join "\N{LINE FEED}", @texts;
}

sub _keys_in_module {
    my ($english) = @_;

    # The code, not the POD, whose synopsis looks a message up by its key.
    my ($source) = split /^__END__$/msx,
      path( $INC{'GPForum/Service/I18N/Catalog.pm'} )->slurp('UTF-8'), 2;

    return [ sort grep { index( $source, qq{'$_'} ) >= 0 } keys %{$english} ];
}

sub _header_problems {
    my ( $locale, $header ) = @_;

    my %expected = ( %HEADER, Language => $locale );
    my @problems;
    for my $field ( sort keys %expected ) {
        my $value = $header->{$field} // '(none)';
        if ( $value ne $expected{$field} ) {
            push @problems, "$field: $value";
        }
    }

    return \@problems;
}

sub _malformed_entries {
    my ($document) = @_;

    my ( %seen, @problems );
    for my $entry ( @{ $document->{entries} } ) {
        my $key = $entry->{context} // q{};
        if ( $key eq q{} ) {
            push @problems, "line $entry->{line}: no msgctxt";
        }
        if ( $seen{$key}++ ) {
            push @problems, "line $entry->{line}: $key again";
        }
    }

    return \@problems;
}

sub _untranslated_entries {
    my ($document) = @_;

    return [
        map  { $_->{context} }
        grep { _is_untranslated($_) } @{ $document->{entries} }
    ];
}

# As gettext has it: a fuzzy entry waits for review, an empty msgstr was
# never written. The catalog shows neither, and falls back to English.
sub _is_untranslated {
    my ($entry) = @_;

    if ( $entry->{flags}{fuzzy} ) {
        return 1;
    }

    return ( grep { $_ eq q{} } _forms($entry) ) ? 1 : 0;
}

sub _key_differences {
    my ( $english, $translated ) = @_;

    return [
        (
            map  { "missing $_" }
            grep { !$translated->{$_} } sort keys %{$english}
        ),
        (
            map { "extra $_" } grep { !$english->{$_} } sort keys %{$translated}
        ),
    ];
}

# msgid is the English each translation was made from, which msgmerge
# updates and marks fuzzy when the English changes.
sub _stale_sources {
    my ( $english, $translated ) = @_;

    my @stale;
    for my $key ( sort grep { $english->{$_} } keys %{$translated} ) {
        my $from = _joined( _sources( $translated->{$key} ) );
        my $now  = _joined( _sources( $english->{$key} ) );
        if ( $from ne $now ) {
            push @stale, $key;
        }
    }

    return \@stale;
}

# An untranslated value is caught too, not only a missing key: a message
# that reads as its English must say so, and one that says so must.
sub _unmarked_copies {
    my ($translated) = @_;

    my @problems;
    for my $key ( sort keys %{$translated} ) {
        my $entry  = $translated->{$key};
        my $copied = _joined( _forms($entry) ) eq _joined( _sources($entry) );
        my $marked = grep { $_ =~ $SAME_AS_ENGLISH } @{ $entry->{comments} };
        if ( $copied && !$marked ) {
            push @problems, "$key reads as the English";
        }
        if ( $marked && !$copied ) {
            push @problems, "$key is marked the same as English but is not";
        }
    }

    return \@problems;
}

sub _english_differences {
    my ($english) = @_;

    return [
        grep {
            _joined( _forms( $english->{$_} ) ) ne
              _joined( _sources( $english->{$_} ) )
        } sort keys %{$english}
    ];
}

# Each form keeps the placeholders of the English source form in its place
# (msgid, or msgid_plural for msgstr[1]). The singular may leave out {count}
# or add it: "a day ago" may be "1 giorno fa".
sub _placeholder_differences {
    my ( $english, $translated ) = @_;

    my @problems;
    for my $key ( sort grep { $english->{$_} } keys %{$translated} ) {
        my @source = _sources( $english->{$key} );
        my @target = _forms( $translated->{$key} );
        my $plural = defined $english->{$key}{id_plural};
        for my $form ( 0 .. $#target ) {
            my $wanted =
              _placeholders( $source[$form] // q{}, $plural && !$form );
            my $found = _placeholders( $target[$form], $plural && !$form );
            if ( $wanted ne $found ) {
                push @problems, "$key [$form]: {$wanted} became {$found}";
            }
        }
    }

    return \@problems;
}

sub _placeholders {
    my ( $text, $count_optional ) = @_;

    my %names = map { $_ => 1 } $text =~ /$PLACEHOLDER/gmsx;
    if ($count_optional) {
        delete $names{count};
    }

    return join q{,}, sort keys %names;
}

# python-brace-format is gettext's name for {name} placeholders: with it,
# msgfmt --check, Poedit and Weblate hold a translation to them as well.
sub _format_flag_problems {
    my ($entries) = @_;

    my @problems;
    for my $key ( sort keys %{$entries} ) {
        my $entry = $entries->{$key};
        my $has   = grep { $_ =~ $PLACEHOLDER } _sources($entry);
        my $flag  = $entry->{flags}{'python-brace-format'} ? 1 : 0;
        if ( ( $has ? 1 : 0 ) != $flag ) {
            push @problems, $key;
        }
    }

    return \@problems;
}

# The keys the templates count with tc() and the relative-time phrases the
# formatter counts.
sub _pluralised_keys {
    my %keys;
    for my $template (
        path('templates')->list_tree->grep(qr/[.]html[.]ep\z/msx)->each )
    {
        my $content = $template->slurp('UTF-8');
        while ( $content =~ /\b tc [(] \s* '([^']+)'/gmsx ) {
            $keys{$1} = 1;
        }
    }
    my $formatter =
      path( $INC{'GPForum/Service/I18N/Formatter.pm'} )->slurp('UTF-8');
    while ( $formatter =~ /'(common[.]time_[[:lower:]]+_ago)'/gmsx ) {
        $keys{$1} = 1;
    }

    my @keys = sort keys %keys;

    return @keys;
}

sub _plural_problems {
    my ( $i18n, $locale, $entries ) = @_;

    my @problems;
    for my $key (
        sort grep { defined $entries->{$_}{id_plural} }
        keys %{$entries}
      )
    {
        my ( $one, $other ) = _forms( $entries->{$key} );
        my %said = (
            1        => $one,
            $SEVERAL => $other,
        );
        for my $count ( sort keys %said ) {
            my $expected = $said{$count} =~ s/[{]count[}]/$count/gmsxr;
            my $got      = $i18n->translate_count( $locale, $key, $count );
            if ( $got ne $expected ) {
                push @problems, "$key x$count: $got";
            }
        }
    }

    return \@problems;
}

sub _which {
    my ($name) = @_;

    for my $directory ( File::Spec->path ) {
        my $candidate = File::Spec->catfile( $directory, $name );
        if ( -x $candidate ) {
            return $candidate;
        }
    }

    return;
}

1;
