# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Test::ResponderController;
use GPForum::Web::LegalAccess;
use Test::Mojo;
use Test::More;

our $VERSION = '0.001';

const my $HTTP_OK            => 200;
const my $SECTION_COUNT      => 5;
const my $TERMS_SECTION_LAST => 'legal.terms.operator';

my $access = GPForum::Web::LegalAccess->new;
ok( $access->known_page('terms'),    'known_page accepts terms' );
ok( $access->known_page('privacy'),  'known_page accepts privacy' );
ok( $access->known_page('cookies'),  'known_page accepts cookies' );
ok( !$access->known_page('unknown'), 'known_page rejects an unknown page' );
is( $access->template, 'legal/page', 'template is the shared legal page' );

my $payload = $access->page_payload( 'terms', 'https://forum.gp/legal/terms' );
is( $payload->{page},      'terms',       'page_payload stores the page name' );
is( $payload->{title_key}, 'legal.terms', 'page_payload stores the title key' );
is( $payload->{heading_id},
    'legal-terms-heading', 'page_payload stores a stable heading id' );
is( scalar @{ $payload->{section_keys} },
    $SECTION_COUNT, 'page_payload lists the terms sections' );
is( $payload->{section_keys}[-1],
    $TERMS_SECTION_LAST, 'page_payload keeps section key order' );
is(
    $payload->{page_metadata}{canonical},
    'https://forum.gp/legal/terms',
    'page_payload stores the canonical URL'
);
is( $payload->{page_metadata}{robots},
    'index,follow', 'page_payload marks legal pages indexable' );
ok(
    !$access->page_payload('unknown'),
    'page_payload is empty for an unknown page'
);

my $html = GPForum::Test::ResponderController->new;
$access->render_page( $html, $payload );
is( $html->last_render->{status}, $HTTP_OK, 'render_page uses HTTP 200' );
is( $html->last_render->{template},
    'legal/page', 'render_page uses the legal page template' );

my $test = Test::Mojo->new('GPForum');

$test->get_ok('/legal/terms');
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'Terms of use' );
$test->element_exists('main');
$test->element_exists('section[aria-labelledby="legal-terms-heading"]');
$test->content_like(qr/not [ ] legal [ ] advice/msx);
$test->element_exists( 'link[rel="canonical"][href$' . '="/legal/terms"]' );
$test->element_exists('footer a[href="/legal/privacy"]');

$test->get_ok('/legal/privacy');
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'Privacy notice' );
$test->content_like(qr/privacy [ ] dashboard/msx);

$test->get_ok('/legal/cookies');
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'Cookie notice' );
$test->content_like(qr/session [ ] cookie/msx);

$test->get_ok( '/legal/terms' => { Accept => 'application/json' } );
$test->status_is($HTTP_OK);
$test->json_is( '/page'      => 'terms' );
$test->json_is( '/title_key' => 'legal.terms' );

$test->get_ok( '/legal/privacy' => { 'Accept-Language' => 'it' } );
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'Informativa privacy' );

done_testing();

1;
