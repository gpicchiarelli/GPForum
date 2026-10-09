# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';

our $VERSION = '0.001';

const my $HTTP_OK     => 200;
const my $MASK_LENGTH => 40;
const my $TOKEN       => qr/\A [[:xdigit:]]{80} \z/msx;

# The CSRF token is masked once per response: every form on a page carries
# the same masked token, the next response carries another, and each unmasks
# to the session's own token, which csrf_protect accepts.
my $test   = Test::Mojo->new('GPForum');
my $routes = $test->app->routes;
$routes->get('/csrf-once/forms')->to(
    cb => sub ($controller) {
        $controller->render(
            inline => '<%= csrf_field %>|<%= csrf_field %>|<%= csrf_token %>'
              . q{|<%= csrf_field(class => 'x') %>} );
    }
);
$routes->post('/csrf-once/check')->to(
    cb => sub ($controller) {
        my $accepted =
          $controller->validation->csrf_protect->has_error('csrf_token')
          ? 'rejected'
          : 'accepted';
        $controller->render( text => $accepted );
    }
);

my ( $first_field, $second_field, $token, $classed ) = _forms();
like( $token, $TOKEN, 'the token is the masked form Mojolicious writes' );
is(
    $first_field,
    qq{<input name="csrf_token" type="hidden" value="$token">},
    'the field is the hidden field hidden_field writes'
);
is( $second_field, $first_field, 'the next form carries the same field' );
is(
    $classed,
    qq{<input class="x" name="csrf_token" type="hidden" value="$token">},
    'a field with attributes of its own goes through the tag helper'
);

my ( undef, undef, $next_token ) = _forms();
isnt( $next_token, $token, 'the next response masks the token anew' );
is( _unmasked($next_token), _unmasked($token),
    'and both unmask to the session token' );

$test->post_ok( '/csrf-once/check', form => { csrf_token => $token } );
$test->status_is($HTTP_OK);
$test->content_is( 'accepted', 'the page token passes csrf_protect' );
$test->post_ok( '/csrf-once/check', form => { csrf_token => $next_token } );
$test->content_is( 'accepted', 'as does the next response token' );

my $stranger = Test::Mojo->new('GPForum');
my $other    = $stranger->app->routes;
$other->post('/csrf-once/check')->to(
    cb => sub ($controller) {
        $controller->render(
            text =>
              $controller->validation->csrf_protect->has_error('csrf_token')
            ? 'rejected'
            : 'accepted'
        );
    }
);
$stranger->post_ok( '/csrf-once/check', form => { csrf_token => $token } );
$stranger->content_is( 'rejected',
    q{another session's token is not this session's} );

done_testing();

sub _forms {
    $test->get_ok('/csrf-once/forms');
    $test->status_is($HTTP_OK);

    return split /[|]/msx, $test->tx->res->text =~ s/\n\z//msxr;
}

# The masked token is the mask's hex and the hex of the token xor the mask.
sub _unmasked ($masked) {
    my $mask  = pack 'H*', substr $masked, 0, $MASK_LENGTH;
    my $xored = pack 'H*', substr $masked, $MASK_LENGTH;

    return unpack 'H*', $mask ^. $xored;
}

1;
