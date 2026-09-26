# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;
use utf8;

use Const::Fast;
use Mojo::File qw(path);
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::I18N;
use GPForum::Test::ForumWebServices;

our $VERSION = '0.001';

const my $HTTP_OK => 200;

my $i18n = GPForum::Service::I18N->new;

is_deeply( $i18n->supported_locales, [qw(en it)],
    'initial catalogs expose English and Italian' );
is( $i18n->negotiate('it-IT,it;q=0.9,en;q=0.2'),
    'it', 'regional Italian negotiates to supported Italian locale' );
is( $i18n->negotiate('en;q=0.3,it;q=0.8'),
    'it', 'Accept-Language quality controls locale preference' );
is( $i18n->negotiate('it;q=0,en;q=0.5'),
    'en', 'zero-quality languages are ignored' );
is( $i18n->negotiate('fr-FR,fr;q=0.8'),
    'en', 'unsupported languages fall back to English default' );
is(
    GPForum::Service::I18N->new( default_locale => 'it' )
      ->negotiate('fr-FR,fr;q=0.8'),
    'it',
    'unsupported languages fall back to configured default locale'
);
is(
    GPForum::Service::I18N->new( default_locale => 'xx' )->negotiate(q{}),
    'en',
    'invalid configured default locale falls back safely to English'
);
is( $i18n->translate( 'it', 'nav.categories' ),
    'Categorie', 'Italian catalog strings translate by key' );
is( $i18n->translate( 'it-IT', 'nav.search' ),
    'Cerca', 'regional locale translation uses supported base catalog' );
is(
    $i18n->translate( 'it', 'auth.signed_in_as', { user_id => 'user-1' } ),
    'Accesso come user-1',
    'template variables interpolate inside translated strings'
);
is(
    $i18n->translate( 'it', 'auth.login_status' ),
    'Hai effettuato l’accesso.',
    'Italian UI uses real apostrophes'
);
is(
    $i18n->translate( 'it', 'forum.last_activity' ),
    'Ultima attività',
    'Italian UI uses real accented letters'
);
is(
    $i18n->translate( 'it', 'search.no_results_guidance' ),
    'Prova una ricerca più ampia, rimuovi un filtro o controlla la scrittura.',
    'Italian guidance uses real grave accents'
);
is( $i18n->translate( 'it', 'missing.key' ),
    'missing.key', 'missing catalog keys return the key' );
is( $i18n->direction('it-IT'), 'ltr', 'locale metadata exposes direction' );
is_deeply( [ sort keys %{ $i18n->locale_registry } ],
    [qw(en it)],
    'locale metadata registry exposes only supported foundation locales' );
is( $i18n->locale_metadata('it')->{script},
    'Latn', 'Italian metadata exposes script for future typography hooks' );
is( $i18n->locale_metadata('fr')->{typography_class},
    'typography-latin',
    'unsupported locale metadata falls back to safe typography defaults' );
is( $i18n->format_date( 'it', 0 ),
    '01/01/1970', 'Italian date formatter uses day-first dates' );
like(
    $i18n->format_time( 'it', 0 ),
    qr/\A [0-9]{2} : [0-9]{2} \z/msx,
    'locale service exposes time formatting abstraction'
);
like(
    $i18n->format_datetime( 'it', 0 ),
    qr/\A [0-9]{2} \/ [0-9]{2} \/ 1970 [ ] [0-9]{2} : [0-9]{2} \z/msx,
    'locale service exposes datetime formatting abstraction'
);
is( $i18n->format_number( 'it', 1234.5 ),
    '1.234,50', 'Italian number formatter uses comma decimals' );
is( $i18n->translate_count( 'it', 'notifications.unread_count', 1 ),
    '1 non letta', 'Italian plural one form is catalog-driven' );
is( $i18n->translate_count( 'it', 'notifications.unread_count', 2 ),
    '2 non lette', 'Italian plural other form is catalog-driven' );
is( $i18n->translate_count( 'en', 'test.items', 2 ),
    'test.items', 'missing plural keys fall back predictably' );

my @missing_events;
my $logging_i18n = GPForum::Service::I18N->new(
    missing_key_logger => sub {
        push @missing_events, shift;
    }
);
$logging_i18n->translate( 'it', 'missing.logged.key' );
is( $missing_events[0]{reason},
    'fallback', 'missing key logger records locale fallback' );
is( $missing_events[1]{reason},
    'missing', 'missing key logger records final missing key' );
is_deeply( $i18n->missing_catalog_keys('it'),
    [], 'Italian catalog covers English catalog keys' );
is_deeply( _missing_template_keys($i18n),
    [], 'template translation helper keys are covered by both catalogs' );
is_deeply( _catalog_namespace_violations($i18n),
    [], 'catalog keys stay inside explicit presentation namespaces' );
is_deeply( _italian_ascii_accent_violations($i18n),
    [], 'Italian UI labels do not use ASCII accent placeholders' );

{
    my $test = _new_test_app('en');

    $test->get_ok( '/' => { 'Accept-Language' => 'it-IT,it;q=0.9,en;q=0.1' } );
    $test->status_is($HTTP_OK);
    $test->header_is( 'Content-Language' => 'it' );
    $test->element_exists(
'html[lang="it"][dir="ltr"][data-locale="it"][data-direction="ltr"][data-script="Latn"]'
    );
    $test->element_exists('body.app-shell.typography-latin');
    $test->text_is(
        'nav[aria-label="Principale"] a[href="/categories"]' => 'Categorie' );
    $test->text_is( 'nav[aria-label="Principale"] a[href="/new-thread"]' =>
          'Avvia una discussione' );
    $test->text_is( 'nav[aria-label="Identità"] a[href="/login"]' => 'Accedi' );
}

{
    my $test = _new_test_app('en');

    $test->get_ok( '/' => { 'Accept-Language' => 'fr-FR,fr;q=0.8' } );
    $test->status_is($HTTP_OK);
    $test->header_is( 'Content-Language' => 'en' );
    $test->element_exists('html[lang="en"]');
    $test->element_exists('nav[aria-label="Primary"] a[href="/categories"]');
}

{
    my $test = _new_test_app('it');

    $test->get_ok( '/' => { 'Accept-Language' => 'zz-ZZ' } );
    $test->status_is($HTTP_OK);
    $test->header_is( 'Content-Language' => 'it' );
    $test->element_exists('html[lang="it"]');
    $test->element_exists('nav[aria-label="Principale"] a[href="/categories"]');
}

{
    my $test = _new_test_app('it');
    _install_test_session_route($test);

    $test->get_ok('/__test/session/user-1');
    $test->status_is($HTTP_OK);
    $test->get_ok( '/' => { 'Accept-Language' => 'it' } );
    $test->status_is($HTTP_OK);

    # 7.5: the header shows the account's links, not its internal id --
    # "Accesso come 018f..." told a member nothing and crowded the header.
    $test->element_exists_not('form[aria-label="Esci"] span');
    $test->content_unlike(qr/Accesso [ ] come/msx);
    $test->text_is(
        'form[aria-label="Esci"] a[href="/settings"]' => 'Impostazioni' );
    $test->text_is( 'form[aria-label="Esci"] button' => 'Esci' );
    $test->element_exists('nav[aria-label="Principale"] a[href="/bookmarks"]');
}

done_testing();

sub _new_test_app {
    my ($default_locale) = @_;

    local $ENV{GPFORUM_DEFAULT_LOCALE} = $default_locale;

    my $test = Test::Mojo->new('GPForum');
    $test->app->helper(
        gp_home_page_reader => sub {
            return GPForum::Test::ForumWebServices->new;
        }
    );

    return $test;
}

sub _install_test_session_route {
    my ($test_object) = @_;

    my $routes = $test_object->app->routes;
    my $route  = $routes->get('/__test/session/:user_id');
    $route->to(
        cb => sub {
            my ($controller) = @_;

            $controller->session( user_id => $controller->param('user_id') );
            return $controller->render( json => { ok => 1 } );
        }
    );

    return;
}

sub _missing_template_keys {
    my ($service) = @_;

    my %seen;
    for my $template (
        path('templates')->list_tree->grep(qr/[.]html[.]ep\z/msx)->each )
    {
        my $content = $template->slurp;
        while ( $content =~ /\b(?:i18n|t|l|tc)\(\s*['"]([^'"]+)['"]/gmsx ) {
            $seen{$1} = 1;
        }
    }

    my @missing;
    for my $key ( sort keys %seen ) {
        for my $locale ( @{ $service->supported_locales } ) {
            push @missing, "$locale:$key"
              if !$service->has_key( $locale, $key );
        }
    }

    return \@missing;
}

sub _catalog_namespace_violations {
    my ($service) = @_;

    my %allowed = map { $_ => 1 } qw(
      admin app auth common community data form forum layout legal locale mentions
      moderation nav notifications permission privacy profile search state target
      settings theme ui
    );
    my @violations;

    for my $locale ( @{ $service->supported_locales } ) {
        for my $key ( @{ $service->catalog_keys($locale) } ) {
            my ($namespace) = split /[.]/msx, $key;
            push @violations, "$locale:$key"
              if !$allowed{$namespace};
        }
    }

    return \@violations;
}

sub _italian_ascii_accent_violations {
    my ($service) = @_;

    my @violations;
    for my $key ( @{ $service->catalog_keys('it') } ) {
        my $message = $service->translate( 'it', $key );
        next if ref $message;
        if ( _has_italian_ascii_accent_placeholder($message) ) {
            push @violations, $key;
        }
    }

    return \@violations;
}

sub _has_italian_ascii_accent_placeholder {
    my ($message) = @_;

    my $normalized = lc $message;
    my @words      = qw(attivita visibilita comunita identita piu);
    my @phrases    = (
        'e temporaneamente',
        'e attivo',
        'e collegata',
        'e disponibile',
        'e bloccata',
        'l accesso',
        'l indice',
        'l interfaccia',
        'l invio',
    );

    for my $word (@words) {
        if ( $normalized =~
            /(?:\A|[^[:alpha:]])\Q$word\E(?:[^[:alpha:]]|\z)/msx )
        {
            return 1;
        }
    }

    for my $phrase (@phrases) {
        if ( $normalized =~
            /(?:\A|[^[:alpha:]])\Q$phrase\E(?:[^[:alpha:]]|\z)/msx )
        {
            return 1;
        }
    }

    return 0;
}

1;
