package main;

use strict;
use warnings;

use Test::Mojo;
use Test::More;

use lib 'lib';

use GPForum::Bootstrap::UI;
use GPForum::View::Presenter;

our $VERSION = '0.001';

can_ok( 'GPForum::Bootstrap::UI', 'register' );

my $presenter = GPForum::View::Presenter->new;

is_deeply(
    $presenter->action(
        href  => '/threads',
        label => 'Threads',
        rel   => 'next',
        class => 'button',
    ),
    {
        class => 'button',
        href  => '/threads',
        label => 'Threads',
        rel   => 'next',
    },
    'action presenter normalizes page actions'
);

is_deeply(
    $presenter->actions(
        { href => '/a', label => 'A' },
        undef,
        { href => '/b', label => 'B' },
    ),
    [ { href => '/a', label => 'A' }, { href => '/b', label => 'B' }, ],
    'actions presenter filters non-action values'
);

is_deeply(
    $presenter->next_page( href => '/next', label => 'More' ),
    [ { href => '/next', label => 'More', rel => 'next' } ],
    'next page presenter builds pagination item'
);

is_deeply( $presenter->next_page( href => q{}, label => 'More' ),
    [], 'next page presenter omits empty pagination' );

is_deeply(
    $presenter->badge( label => 'Open', tone => 'warning' ),
    { label => 'Open', tone => 'warning' },
    'badge presenter normalizes status badge data'
);

my $test       = Test::Mojo->new('GPForum');
my $controller = $test->app->build_controller;

$test->app->routes->get('/__bootstrap-ui')->to(
    cb => sub {
        my ($controller) = @_;

        return $controller->render( text => $controller->t('nav.search') );
    }
);

is_deeply(
    $controller->ui_actions(
        { href => '/admin',  label => 'Admin' },
        { href => '/status', label => 'Status' },
    ),
    [
        { href => '/admin',  label => 'Admin' },
        { href => '/status', label => 'Status' },
    ],
    'ui_actions helper delegates to presenter'
);

is_deeply(
    $controller->ui_next_page( href => '/older', label => 'Older' ),
    [ { href => '/older', label => 'Older', rel => 'next' } ],
    'ui_next_page helper delegates to presenter'
);

is_deeply(
    $controller->ui_badge( 'state', 'ok' ),
    { label => 'OK', tone => 'success' },
    'ui_badge helper localizes label and status tone'
);

is( $controller->ui_tone( 'state', 'suspended' ),
    'danger', 'ui_tone accepts namespaced calls for template ergonomics' );

$test->get_ok( '/__bootstrap-ui' => { 'Accept-Language' => 'it' } )
  ->status_is(200)
  ->header_is( 'Content-Language' => 'it' )
  ->content_is('Cerca');

done_testing();

1;
