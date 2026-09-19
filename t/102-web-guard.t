package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Test::ResponderController;
use GPForum::Web::Guard;
use Test::More;

our $VERSION = '0.001';

const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_CONFLICT     => 409;
const my $HTTP_TOO_MANY     => 429;

my $controller =
  GPForum::Test::ResponderController->new( accept_header => 'application/json',
  );
my $guard = GPForum::Web::Guard->new;

$guard->unauthorized($controller);
is( $controller->last_render->{status},
    $HTTP_UNAUTHORIZED, 'unauthorized uses HTTP 401' );
is( $controller->last_render->{json}{status},
    'unauthorized', 'unauthorized uses the shared payload' );

$guard->forbidden( $controller, { error => 'post author required' } );
is( $controller->last_render->{status},
    $HTTP_FORBIDDEN, 'forbidden uses HTTP 403' );
is(
    $controller->last_render->{json}{error},
    'post author required',
    'forbidden accepts a custom error'
);

$guard->rate_limited(
    $controller,
    {
        error => 'rate limit exceeded',
        title => 'Rate limited',
    }
);
is( $controller->last_render->{status},
    $HTTP_TOO_MANY, 'rate_limited uses HTTP 429' );
is(
    $controller->last_render->{json}{error},
    'rate limit exceeded',
    'rate_limited accepts a custom error'
);

$guard->conflict(
    $controller,
    {
        error => 'idempotency conflict',
        title => 'Conflict',
    }
);
is( $controller->last_render->{status},
    $HTTP_CONFLICT, 'conflict uses HTTP 409' );

done_testing();

1;
