# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;
use utf8;

use Const::Fast;
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Mojo::Util qw(encode);
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Service::I18N;
use GPForum::Service::I18N::Catalog;
use GPForum::Service::I18N::PoFile;

our $VERSION = '0.001';

const my $READER  => 'GPForum::Service::I18N::PoFile';
const my $CATALOG => 'GPForum::Service::I18N::Catalog';

# The header _header() writes is five lines and a blank one, so a body's
# first line is the file's seventh.
const my $BODY_LINE => 7;

# The body that repeats a message has it at its first line and again at its
# fifth, after a msgstr and a blank line.
const my $REPEATED_AT => 4;
const my $SEVERAL     => 3;

# A byte that cannot begin a UTF-8 sequence.
const my $NOT_UTF8 => chr 0xFF;

# --- The reader -------------------------------------------------------------

{
    my $text = "\N{BYTE ORDER MARK}" . join "\r\n",
      q{# A file comment, which is the header entry's.},
      'msgid ""',
      'msgstr ""',
      '"Language: it\n"',
      '"Content-Type: text/plain; charset=UTF-8\n"',
      '"Plural-Forms: nplurals=2; plural=(n != 1);\n"',
      q{},
      '# Same as English.',
      '#. A note from the code, skipped.',
      '#: templates/x.html.ep:3',
      '#, python-brace-format , no-wrap',
      'msgctxt "auth.greeting"',
      'msgid ""',
      '"Hello, "',
      '"{name}"',
      'msgstr "Ciao, \"{name}\"\\\\\r\n\t"',
      'msgctxt "admin.items"',
      'msgid "{count} item"',
      'msgid_plural "{count} items"',
      'msgstr[0] "{count} voce"',
      'msgstr[1] "{count} voci"',
      q{},
      '#, fuzzy',
      '#~ msgctxt "gone"',
      '#~ msgid "Gone"',
      '#~ msgstr "Andato"',
      q{},
      '#| msgid "Start"',
      'msgctxt "nav.home"',
      'msgid "Home"',
      'msgstr ""',
      '"Ini"',
      q{},
      '"zio"',
      '# A comment with no entry after it.';

    my $document = $READER->parse( $text, 'sample.po' );
    is_deeply(
        $document->{header},
        {
            Language       => 'it',
            'Content-Type' => 'text/plain; charset=UTF-8',
            'Plural-Forms' => 'nplurals=2; plural=(n != 1);',
        },
        'the header entry becomes its fields'
    );
    is_deeply(
        $document->{entries},
        [
            {
                context   => 'auth.greeting',
                id        => 'Hello, {name}',
                id_plural => undef,
                strings   => ["Ciao, \"{name}\"\\\r\n\t"],
                flags     => { 'python-brace-format' => 1, 'no-wrap' => 1 },
                comments  => ['Same as English.'],
                line      => 12,
            },
            {
                context   => 'admin.items',
                id        => '{count} item',
                id_plural => '{count} items',
                strings   => [ '{count} voce', '{count} voci' ],
                flags     => {},
                comments  => [],
                line      => 17,
            },
            {
                context   => 'nav.home',
                id        => 'Home',
                id_plural => undef,
                strings   => ['Inizio'],
                flags     => {},
                comments  => [],
                line      => 29,
            },
        ],
        q{continued strings join, escapes unfold, the tools' comments are}
          . ' skipped, and obsolete entries and their flags stay out'
    );
}

# Each malformed body croaks with the file and the line at fault.
for my $case (
    [
        'an unterminated string',
        [ 'msgctxt "k"', 'msgid "Open' ],
        1,
        'not one "quoted" string',
    ],
    [
        'an unknown escape',
        [ 'msgctxt "k"', 'msgid "a\qb"' ],
        1, 'unknown escape \q',
    ],
    [ 'a bare word', [ 'msgctxt "k"', 'msgid Open' ], 1, 'not one "quoted"' ],
    [
        'a line that is nothing',
        [ 'msgctxt "k"', 'Open' ],
        1,
        'not a comment, a keyword or a string',
    ],
    [
        'a string after a comment',
        [ '# note', '"Open"' ],
        1,
        'a string with no keyword before it',
    ],
    [
        'msgstr first', [ 'msgctxt "k"', 'msgstr "x"' ],
        1,              'msgstr before msgid',
    ],
    [
        'two msgids', [ 'msgid "a"', 'msgid "b"', 'msgstr "x"' ],
        1,            'a second msgid before a msgstr',
    ],
    [
        'msgctxt after msgid',
        [ 'msgid "a"', 'msgctxt "k"', 'msgstr "x"' ],
        1, 'msgctxt must open its entry',
    ],
    [
        'two msgstrs', [ 'msgid "a"', 'msgstr "x"', 'msgstr "y"' ],
        2,             'a second msgstr',
    ],
    [
        'msgid_plural after msgstr',
        [ 'msgid "a"', 'msgstr "x"', 'msgid_plural "as"' ],
        2, 'msgid_plural must follow its msgid',
    ],
    [
        'msgid_plural before msgid',
        [ 'msgctxt "k"', 'msgid_plural "as"' ],
        1,
        'msgid_plural must follow its msgid',
    ],
    [
        'two msgid_plurals',
        [ 'msgid "a"', 'msgid_plural "as"', 'msgid_plural "bs"' ],
        2, 'msgid_plural must follow its msgid',
    ],
    [
        'a numbered msgstr in a plain entry',
        [ 'msgid "a"', 'msgstr[0] "x"' ],
        1,
        'msgstr[0] in an entry without msgid_plural',
    ],
    [
        'a plain msgstr in a plural entry',
        [ 'msgid "a"', 'msgid_plural "as"', 'msgstr "x"' ],
        2,
        'a plural entry numbers its forms',
    ],
    [
        'forms out of order',
        [ 'msgid "a"', 'msgid_plural "as"', 'msgstr[1] "x"' ],
        2, 'msgstr[1] where msgstr[0] belongs',
    ],
    [ 'a numbered msgid', ['msgid[0] "a"'], 0, 'msgid takes no [0]' ],
    [
        'a comment inside an entry',
        [ 'msgid "a"', '# note', 'msgstr "x"' ],
        1,
        'a comment inside an entry',
    ],
    [
        'an entry with no msgstr',
        [ 'msgctxt "k"', 'msgid "a"' ],
        0,
        'an entry needs a msgid and a msgstr',
    ],
    [
        'the same message twice',
        [
            'msgctxt "k"',
            'msgid "a"',
            'msgstr "x"',
            q{},
            'msgctxt "k"',
            'msgid "a"',
            'msgstr "y"',
        ],
        $REPEATED_AT,
        "the same message as line $BODY_LINE",
    ],
    [
        'three forms where two are declared',
        [
            'msgid "a"',
            'msgid_plural "as"',
            'msgstr[0] "x"',
            'msgstr[1] "y"',
            'msgstr[2] "z"',
        ],
        0,
        '3 plural forms where Plural-Forms declares 2',
    ],
    [
        'one form where two are declared',
        [ 'msgid "a"', 'msgid_plural "as"', 'msgstr[0] "x"' ],
        0,
        '1 plural forms where Plural-Forms declares 2',
    ],
    [
        'a second header',
        [ 'msgid ""', 'msgstr "Language: it\n"' ],
        0, 'the same message as line 1',
    ],
  )
{
    my ( $name, $body, $offset, $problem ) = @{$case};
    my $line = $BODY_LINE + $offset;
    throws_ok { $READER->parse( _header() . join( "\n", @{$body} ), 'bad.po' ) }
    qr/\A bad[.]po [ ] line [ ] $line: [ ] \Q$problem\E/msx,
      "$name is refused, at line $line";
}

throws_ok {
    $READER->parse( qq{msgctxt "k"\nmsgid "a"\nmsgstr "x"\n}, 'bad.po' )
}
qr/\A bad[.]po: [ ] no [ ] header [ ] entry/msx, 'a file with no header';
throws_ok {
    $READER->parse( qq{msgid "a"\nmsgstr "x"\n\n} . _header(), 'bad.po' )
}
qr/\A bad[.]po [ ] line [ ] 4: [ ] the [ ] header .* first [ ] entry/msx,
  'a header after the first entry';
throws_ok {
    $READER->parse( _header( charset => 'ISO-8859-1' ), 'bad.po' )
}
qr/\A bad[.]po: [ ] the [ ] header [ ] must [ ] declare [ ] charset=UTF-8/msx,
  'a charset other than UTF-8';
throws_ok {
    $READER->parse( qq{msgid ""\nmsgstr "Language it\\n"\n}, 'bad.po' )
}
qr/'Language [ ] it' [ ] is [ ] not [ ] 'Field: [ ] value'/msx,
  'a header line that is not a field';
throws_ok {
    $READER->parse(
        _header( plural_forms => undef )
          . qq{msgid "a"\nmsgid_plural "as"\nmsgstr[0] "x"\nmsgstr[1] "y"\n},
        'bad.po'
    )
}
qr/line [ ] 7: [ ] a [ ] plural [ ] entry, [ ] but .* no [ ] Plural-Forms/msx,
  'a plural entry under a header with no Plural-Forms';

{
    my $file = path( tempdir( CLEANUP => 1 ) )->child('it.po');
    $file->spew( encode( 'UTF-8', _header() ) . qq{msgid "$NOT_UTF8"\n} );
    throws_ok { $READER->read_file( $file->to_string ) }
    qr/it[.]po [ ] is [ ] not [ ] valid [ ] UTF-8/msx,
      'a file that is not UTF-8';
}

# --- The catalog loader -----------------------------------------------------

{
    my $directory = _catalogs(
        'en.po' => _header( language => 'en' )
          . _messages(
            [ 'auth.greeting', 'Hello, {name}', 'Hello, {name}' ],
            [ 'nav.pending',   'Pending',       'Pending' ],
            [ 'nav.blank',     'Blank',         'Blank' ],
            [
                'admin.items',
                '{count} item',
                '{count} item',
                '{count} items',
                '{count} items',
            ],
            [
                'admin.pages',
                '{count} page',
                '{count} page',
                '{count} pages',
                '{count} pages',
            ],
          ),
        'it.po' => _header()
          . _messages(
            [ 'auth.greeting', 'Hello, {name}', 'Ciao, {name}' ],
            [ 'nav.pending',   'Pending',       'In attesa', 'fuzzy' ],
            [ 'nav.blank',     'Blank',         q{} ],
            [
                'admin.items',
                '{count} item',
                '{count} voce',
                '{count} items',
                '{count} voci',
            ],
            [
                'admin.pages',
                '{count} page',
                '{count} pagina',
                '{count} pages',
                q{},
            ],
          ),
        'de.po' => _header( language => 'de' ),

        # The same rule, spelled without the parentheses.
        'pt-br.po' => _header(
            language     => 'pt_BR',
            plural_forms => 'nplurals=2; plural=n != 1;',
        ),
        'gpforum.pot' => 'not read',
        'README'      => 'not read',
        'en.po.orig'  => 'not read',

        # An editor's lock file and the AppleDouble file a macOS archive
        # leaves beside each file it copies.
        '.#it.po' => 'not read',
        '._en.po' => 'not read',
    );

    my $catalogs = $CATALOG->load_catalogs($directory);
    is_deeply(
        $catalogs,
        {
            en => {
                'auth.greeting' => 'Hello, {name}',
                'nav.pending'   => 'Pending',
                'nav.blank'     => 'Blank',
                'admin.items'   =>
                  { one => '{count} item', other => '{count} items' },
                'admin.pages' =>
                  { one => '{count} page', other => '{count} pages' },
            },
            it => {
                'auth.greeting' => 'Ciao, {name}',
                'admin.items'   =>
                  { one => '{count} voce', other => '{count} voci' },
            },
            de      => {},
            'pt-br' => {},
        },
        'each locale is its PO file; fuzzy and empty translations are left out,'
          . ' a plural one with any form empty among them'
    );

    my @missing;
    my $i18n = GPForum::Service::I18N->new(
        catalogs           => $catalogs,
        missing_key_logger => sub { push @missing, shift },
    );
    is_deeply( $i18n->supported_locales, [qw(de en it pt-br)],
        'the supported locales are the PO files' );
    is( $i18n->translate( 'it', 'auth.greeting', { name => 'Ada' } ),
        'Ciao, Ada', 'a translated message reads in its locale' );
    is( $i18n->translate( 'it', 'nav.pending' ),
        'Pending', 'a fuzzy one falls back to English' );
    is( $i18n->translate( 'it', 'nav.blank' ),
        'Blank', 'and so does an untranslated one' );
    is_deeply(
        \@missing,
        [
            { key => 'nav.pending', locale => 'it', reason => 'fallback' },
            { key => 'nav.blank',   locale => 'it', reason => 'fallback' },
        ],
        'and each fallback is logged'
    );
    is( $i18n->translate_count( 'it', 'admin.items', 1 ),
        '1 voce', 'msgstr[0] is the form for one' );
    is(
        $i18n->translate_count( 'it', 'admin.items', $SEVERAL ),
        "$SEVERAL voci",
        'msgstr[1] the form for any other count'
    );

    # Shown as it is, the empty form would print nothing for a count of
    # several; the message falls back whole instead, both forms English.
    @missing = ();
    is(
        $i18n->translate_count( 'it', 'admin.pages', $SEVERAL ),
        "$SEVERAL pages",
        'a plural message with a form left empty falls back to English'
    );
    is( $i18n->translate_count( 'it', 'admin.pages', 1 ),
        '1 page', 'its other form too' );
    my $fallback =
      { key => 'admin.pages', locale => 'it', reason => 'fallback' };
    is_deeply(
        \@missing,
        [ $fallback, $fallback ],
        'and each fallback is logged'
    );
}

# The loader refuses a malformed catalog rather than serve its keys.
for my $case (
    [
        'a malformed file',
        { 'it.po' => _header() . qq{msgctxt "k"\nmsgid "a\n} },
        qr/it[.]po [ ] line [ ] 8: [ ] not [ ] one [ ] "quoted" [ ] string/msx,
    ],
    [
        'a key twice',
        {
            'it.po' => _header()
              . _messages( [ 'k', 'A', 'x' ], [ 'k', 'B', 'y' ] )
        },
qr/it[.]po [ ] line [ ] 11: [ ] k [ ] is [ ] already [ ] on [ ] line [ ] 7/msx,
    ],
    [
        'a message without a key',
        { 'it.po' => _header() . qq{msgid "A"\nmsgstr "x"\n} },
qr/it[.]po [ ] line [ ] 7: [ ] a [ ] message [ ] needs [ ] its [ ] key/msx,
    ],
    [
        'a header naming another language',
        { 'it.po' => _header( language => 'en' ) },
qr/it[.]po: [ ] its [ ] header [ ] says [ ] Language: [ ] en, [ ] not [ ] it/msx,
    ],
    [
        'a header with no Language',
        { 'it.po' => _header( language => undef ) },
qr/it[.]po: [ ] its [ ] header [ ] says [ ] Language: [ ] , [ ] not [ ] it/msx,
    ],
    [
        'a plural rule the formatter cannot serve',
        {
            'pl.po' => _header(
                language     => 'pl',
                plural_forms => 'nplurals=3; plural=(n==1 ? 0 : n%10>=2'
                  . ' && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);',
            )
        },
        qr/pl[.]po: [ ] Plural-Forms [ ] .* [ ] is [ ] not [ ] the [ ] rule/msx,
    ],
    [
        'a file not named for a locale',
        { 'pt_BR.po' => _header( language => 'pt_BR' ) },
        qr/pt_BR[.]po: [ ] a [ ] catalog [ ] is [ ] named [ ] after [ ] its/msx,
    ],
    [
        'no English catalog',
        { 'en.po' => undef },
        qr/has [ ] no [ ] en[.]po/msx,
    ],
  )
{
    my ( $name, $files, $problem ) = @{$case};
    my %files = (
        'en.po' => _header( language => 'en' ),
        'it.po' => _header(),
        %{$files},
    );
    my $directory = _catalogs(
        map  { ( $_ => $files{$_} ) }
        grep { defined $files{$_} } keys %files
    );
    throws_ok { $CATALOG->load_catalogs($directory) } $problem,
      "the loader refuses $name";
}

{
    my $first = $CATALOG->default_catalogs;
    $first->{en}{'nav.home'} = 'Changed';
    $first->{en}{'notifications.unread_count'}{one} = 'Changed';
    my $fresh = $CATALOG->default_catalogs;
    isnt( $fresh->{en}{'nav.home'},
        'Changed', 'each caller gets its own copy of the catalogs' );
    isnt( $fresh->{en}{'notifications.unread_count'}{one},
        'Changed', 'down to the plural forms' );
}

done_testing();

sub _header {
    my (%input) = @_;

    my %field = (
        language     => 'it',
        charset      => 'UTF-8',
        plural_forms => 'nplurals=2; plural=(n != 1);',
        %input,
    );
    my $plural =
      defined $field{plural_forms}
      ? qq{"Plural-Forms: $field{plural_forms}\\n"\n}
      : qq{"X-Generator: test\\n"\n};
    my $language =
      defined $field{language}
      ? qq{"Language: $field{language}\\n"\n}
      : qq{"Language-Team: test\\n"\n};

    return
        qq{msgid ""\nmsgstr ""\n}
      . $language
      . qq{"Content-Type: text/plain; charset=$field{charset}\\n"\n}
      . $plural . qq{\n};
}

# Each message is [ key, msgid, msgstr ], with a flag after it, or
# [ key, msgid, msgstr[0], msgid_plural, msgstr[1] ] for a plural one.
sub _messages {
    my (@messages) = @_;

    my $text = q{};
    for my $message (@messages) {
        my ( $key, $id, $string, @rest ) = @{$message};
        if ( @rest == 1 ) {
            $text .= "#, $rest[0]\n";
        }
        $text .= qq{msgctxt "$key"\nmsgid "$id"\n};
        if ( @rest == 2 ) {
            $text .= qq{msgid_plural "$rest[0]"\n}
              . qq{msgstr[0] "$string"\nmsgstr[1] "$rest[1]"\n\n};
            next;
        }
        $text .= qq{msgstr "$string"\n\n};
    }

    return $text;
}

sub _catalogs {
    my (%files) = @_;

    my $directory = path( tempdir( CLEANUP => 1 ) );
    for my $name ( keys %files ) {
        $directory->child($name)->spew( encode( 'UTF-8', $files{$name} ) );
    }

    return $directory->to_string;
}

1;
