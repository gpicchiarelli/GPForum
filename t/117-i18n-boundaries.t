package main;

use strict;
use warnings;
use utf8;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Service::I18N;
use GPForum::Service::I18N::Catalog;
use GPForum::Service::I18N::Formatter;
use GPForum::Service::I18N::Locale;
use Test::More;

our $VERSION = '0.001';

const my $SAMPLE_NUMBER => 1234.5;

my $catalog = GPForum::Service::I18N::Catalog->new;
is( $catalog->message( 'it', 'nav.categories' ),
    'Categorie', 'catalog returns Italian presentation strings' );
is(
    $catalog->interpolate( 'Accesso come {user_id}', { user_id => 'user-1' } ),
    'Accesso come user-1',
    'catalog interpolates named placeholders'
);
is_deeply( $catalog->missing_keys('it'),
    [], 'Italian catalog covers English keys' );

my $locales =
  GPForum::Service::I18N::Locale->new( supported => { en => 1, it => 1 }, );
is( $locales->negotiate('it-IT,it;q=0.9,en;q=0.2'),
    'it', 'locale negotiation prefers regional Italian' );
is( $locales->negotiate('en;q=0.3,it;q=0.8'),
    'it', 'locale negotiation honors quality values' );
is( $locales->negotiate('it;q=0,en;q=0.5'),
    'en', 'locale negotiation ignores zero-quality languages' );
is( $locales->negotiate('fr-FR,fr;q=0.8'),
    'en', 'locale negotiation falls back to English' );
is( $locales->direction('it-IT'), 'ltr', 'locale metadata exposes direction' );

my $formats =
  GPForum::Service::I18N::Formatter->new( locale_table => $locales, );
is( $formats->format_number( 'it', $SAMPLE_NUMBER ),
    '1.234,50', 'formatter uses Italian decimal and thousand marks' );
is( $formats->plural_category( 'it', 1 ),
    'one', 'formatter classifies singular counts' );
is( $formats->plural_category( 'it', 2 ),
    'other', 'formatter classifies remaining counts' );

my $i18n = GPForum::Service::I18N->new;
is( $i18n->translate( 'it', 'nav.categories' ),
    'Categorie', 'I18N facade still translates from catalogs' );
is(
    $i18n->translate( 'it', 'auth.signed_in_as', { user_id => 'user-1' } ),
    'Accesso come user-1',
    'I18N facade still interpolates catalog variables'
);
is( $i18n->translate_count( 'it', 'notifications.unread_count', 1 ),
    '1 non letta', 'I18N facade still selects plural one forms' );
is( $i18n->format_number( 'it', $SAMPLE_NUMBER ),
    '1.234,50', 'I18N facade still formats numbers' );

done_testing();

1;
