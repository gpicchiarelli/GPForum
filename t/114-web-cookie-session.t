package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Test::CookieSessionController;
use GPForum::Web::CookieSession;
use Test::More;

our $VERSION = '0.001';

const my $NOW             => 1_716_464_000;
const my $FUTURE_EPOCH    => $NOW + 1;
const my $PAST_EPOCH      => $NOW - 1;
const my $SESSION_SECONDS => 2_592_000;

my $cookies = GPForum::Web::CookieSession->new;
my $live    = GPForum::Test::CookieSessionController->new(
    data => {
        session_expires_at_epoch => $FUTURE_EPOCH,
        session_id               => 'sess-1',
        user_id                  => 'user-1',
    },
);

ok( $cookies->has_server_session($live),
    'has_server_session accepts session_id and user_id' );
ok( !$cookies->expired( $live, $NOW ),
    'expired is false before session_expires_at_epoch' );

my $missing =
  GPForum::Test::CookieSessionController->new( data => { user_id => 'user-1' },
  );
ok(
    !$cookies->has_server_session($missing),
    'has_server_session rejects a missing session_id'
);

my $stale = GPForum::Test::CookieSessionController->new(
    data => { session_expires_at_epoch => $PAST_EPOCH }, );
ok( $cookies->expired( $stale, $NOW ),
    'expired is true after session_expires_at_epoch' );

my $cleared = GPForum::Test::CookieSessionController->new(
    data => {
        login_rotation           => 'rot-1',
        preferred_locale         => 'it',
        session_expires_at_epoch => $FUTURE_EPOCH,
        session_id               => 'sess-1',
        user_id                  => 'user-1',
    },
);
$cookies->clear($cleared);
ok( !exists $cleared->data->{user_id},    'clear deletes user_id' );
ok( !exists $cleared->data->{session_id}, 'clear deletes session_id' );
is( $cleared->data->{preferred_locale},
    'it', 'clear keeps locale preference cookies' );
ok( $cleared->expired, 'clear expires the Mojolicious session cookie' );

$cookies->replace_login(
    $cleared,
    {
        expires_at       => $FUTURE_EPOCH,
        preferred_locale => 'en',
        preferred_theme  => 'high_contrast',
        rotation         => 'rot-2',
        session_id       => 'sess-2',
        user_id          => 'user-2',
    }
);
is( $cleared->data->{user_id},    'user-2', 'replace_login writes user_id' );
is( $cleared->data->{session_id}, 'sess-2', 'replace_login writes session_id' );
is( $cleared->data->{preferred_locale},
    'en', 'replace_login writes preferred_locale' );
is( $cleared->data->{login_rotation},
    'rot-2', 'replace_login writes login_rotation' );

is( $cookies->validation_reason(undef),
    'validation_failed', 'validation_reason maps a missing result' );
is( $cookies->validation_reason( { ok => 0, error => 'revoked' } ),
    'revoked', 'validation_reason returns the store error' );
is( $cookies->validation_reason( { ok => 0 } ),
    'validation_failed', 'validation_reason defaults a missing error' );

is( $cookies->session_seconds,
    $SESSION_SECONDS, 'session_seconds keeps the 30-day lifetime' );
is(
    $cookies->expires_at($NOW),
    $NOW + $SESSION_SECONDS,
    'expires_at adds the lifetime to now'
);

done_testing();

1;
