# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Mojolicious;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Web::UrlId;

our $VERSION = '0.001';

const my $UUID  => '018f1006-0001-7000-8000-000000000001';
const my $UPPER => '018F1006-00AB-7000-8000-0000000000CD';

# A Const::Fast hash, as the controllers pass: reading a key it lacks dies.
const my %NOUN => ( action_id => 'moderation action' );

my $test = Test::Mojo->new( _application() );

$test->get_ok("/threads/$UUID/a-slug")->json_is( '/malformed' => undef );
$test->get_ok("/threads/$UPPER/a-slug")
  ->json_is( '/malformed' => undef, 'hex digits in either case are a uuid' );
$test->get_ok('/threads/thread-1/a-slug')
  ->json_is( '/malformed' => 'thread_id', 'a word is not' );
$test->get_ok("/threads/${UUID}0/a-slug")
  ->json_is( '/malformed' => 'thread_id', 'nor a uuid with a digit more' );
$test->get_ok("/threads/$UUID/not-a-uuid")->json_is(
    '/malformed' => undef,
    'a placeholder not named *_id is not checked: a slug is no id'
);

$test->get_ok("/spaces/$UUID/items/$UUID")->json_is( '/malformed' => undef );
$test->get_ok("/spaces/space-1/items/$UUID")->json_is(
    '/malformed' => 'space_id',
    'the placeholders of an enclosing route are checked too'
);
$test->get_ok("/spaces/$UUID/items/item-1")
  ->json_is( '/malformed' => 'item_id' );

$test->get_ok('/plain')
  ->json_is( '/malformed' => undef, 'a route without ids always passes' );

ok( !GPForum::Web::UrlId->malformed(undef),   'no filter is not malformed' );
ok( !GPForum::Web::UrlId->malformed(q{}),     'nor an empty one' );
ok( !GPForum::Web::UrlId->malformed($UUID),   'nor a uuid' );
ok( GPForum::Web::UrlId->malformed('user-2'), 'a word is' );

is(
    GPForum::Web::UrlId->not_found_error('thread_id'),
    'thread not found',
    'the error names the row'
);
is(
    GPForum::Web::UrlId->not_found_error('export_request_id'),
    'export request not found',
    'in words'
);
is(
    GPForum::Web::UrlId->not_found_error(undef),
    'not found',
    'or says only not found'
);

# The workflow says "moderation action not found" for a missing action; the
# name alone gave "action not found", a second answer for the same 404.
is(
    GPForum::Web::UrlId->not_found_error( 'action_id', \%NOUN ),
    'moderation action not found',
    'a noun given for the placeholder is the one used'
);
is(
    GPForum::Web::UrlId->not_found_error( 'thread_id', \%NOUN ),
    'thread not found',
    'a placeholder the nouns do not name is still spelled from its name'
);

done_testing();

sub _application {
    my $application = Mojolicious->new;
    $application->log->level('fatal');

    my $probe = sub {
        my ($controller) = @_;

        return $controller->render(
            json => {
                malformed =>
                  scalar GPForum::Web::UrlId->malformed_path_id($controller)
            }
        );
    };
    my $routes = $application->routes;
    $routes->get('/threads/:thread_id/:slug')->to( cb => $probe );
    $routes->any('/spaces/:space_id')
      ->get('/items/:item_id')
      ->to( cb => $probe );
    $routes->get('/plain')->to( cb => $probe );

    return $application;
}

1;
