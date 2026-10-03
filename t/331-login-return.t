# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::ForumWebServices;
use GPForum::Test::IdentitySecurityAudit;
use GPForum::Test::IdentityStore;

our $VERSION = '0.001';

const my $HTTP_ACCEPTED => 202;
const my $HTTP_FOUND    => 302;
const my $HTTP_OK       => 200;

# Signing in answered with a page that said "Login request accepted", which
# the reader had to leave at once. It now sends them on: to the page the
# login form was reached from, when that is a page of this forum and not
# itself part of signing in, and to the home page otherwise.
const my @RETURNS => (
    [ '/t/thread-1',           '/t/thread-1',      'a page of the forum' ],
    [ '/search?q=indice',      '/search?q=indice', 'with its query' ],
    [ undef,                   q{/},               'no page named' ],
    [ 'https://evil.example/', q{/},               'another site' ],
    [ '//evil.example/',       q{/}, 'a protocol-relative address' ],
    [ '/login',                q{/}, 'the login page itself' ],
    [ '/register',             q{/}, 'the registration page' ],
    [ '/password/reset',       q{/}, 'the password reset page' ],
);

for my $case (@RETURNS) {
    my ( $return_to, $expected, $name ) = @{$case};

    my $test = _forum();
    my $form = $test->app->url_for('login');
    if ( defined $return_to ) {
        $form = $form->query( return_to => $return_to );
    }
    $test->get_ok($form)->status_is($HTTP_OK);
    is(
        _field( $test, 'return_to' ),
        $return_to // q{},
        "$name: the form carries what it was given"
    );

    $test->post_ok(
        '/login' => form => {
            command_id => _field( $test, 'command_id' ),
            csrf_token => _field( $test, 'csrf_token' ),
            identifier => 'giacomo_forum',
            password   => 'correct horse battery staple',
            defined $return_to ? ( return_to => $return_to ) : (),
        }
    );
    $test->status_is($HTTP_FOUND);
    $test->header_is( Location => $expected, "$name: leads to $expected" );
}

# The page a reader lands on says what happened, once.
my $reader = _forum();
$reader->get_ok('/login?return_to=%2Fcategories')->status_is($HTTP_OK);
$reader->post_ok(
    '/login' => form => {
        command_id => _field( $reader, 'command_id' ),
        csrf_token => _field( $reader, 'csrf_token' ),
        identifier => 'giacomo_forum',
        password   => 'correct horse battery staple',
        return_to  => '/categories',
    }
);
$reader->get_ok('/categories')->status_is($HTTP_OK);
$reader->text_is( 'p.flash--success[role="status"]' => 'You are signed in' );
$reader->element_exists('form[action="/logout"]');
$reader->get_ok('/categories');
$reader->element_exists_not('p.flash--success');

# A client that asked for JSON keeps the answer it always had.
my $client = _forum();
$client->get_ok('/login')->status_is($HTTP_OK);
$client->post_ok(
    '/login' => { Accept => 'application/json' } => form => {
        command_id => _field( $client, 'command_id' ),
        csrf_token => _field( $client, 'csrf_token' ),
        identifier => 'giacomo_forum',
        password   => 'correct horse battery staple',
    }
);
$client->status_is($HTTP_ACCEPTED);

# The way in is offered with the way back: the header's link names the page
# it is on, except on the home page and on the pages that are the way in.
my $visitor = _forum();
$visitor->get_ok('/categories');
$visitor->element_exists(
    'header.site-header a[href="/login?return_to=%2Fcategories"]');
for my $page ( q{/}, '/login', '/register' ) {
    $visitor->get_ok($page);
    $visitor->element_exists(
        'header.site-header a[href="/login"]',
        "$page links to the login form alone"
    );
}

done_testing();

sub _field {
    my ( $test_object, $name ) = @_;

    my $page  = $test_object->tx->res->dom;
    my $input = $page->at(qq{form[action="/login"] input[name="$name"]});

    return $input ? $input->attr('value') : undef;
}

sub _forum {
    my $test_object = Test::Mojo->new('GPForum');

    my $identity = GPForum::Test::IdentityStore->new;
    my $services = GPForum::Test::ForumWebServices->new;
    $test_object->app->helper( gp_identity_store => sub { return $identity } );
    $test_object->app->helper( gp_profile_reader => sub { return $identity } );
    $test_object->app->helper(
        gp_identity_security_audit => sub {
            return GPForum::Test::IdentitySecurityAudit->new;
        }
    );
    for my $helper (
        qw(
        gp_category_reader gp_home_page_reader gp_thread_reader
        gp_thread_detail_reader gp_post_reader gp_thread_read_state
        gp_bookmark_store gp_subscription_store gp_search_service
        gp_rate_limiter gp_suspension_store gp_attachment_store
        )
      )
    {
        $test_object->app->helper( $helper => sub { return $services } );
    }

    return $test_object;
}

1;
