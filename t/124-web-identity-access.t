# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Test::ResponderController;
use GPForum::Web::IdentityAccess;
use Test::More;

our $VERSION = '0.001';

const my $HTTP_BAD_REQUEST         => 400;
const my $HTTP_FORBIDDEN           => 403;
const my $HTTP_SERVER_ERROR        => 500;
const my $HTTP_SERVICE_UNAVAILABLE => 503;
const my $HTTP_TOO_MANY            => 429;
const my $LOGIN_LIMIT              => 10;
const my $LOGOUT_LIMIT             => 20;
const my $PASSWORD_LIMIT           => 5;
const my $REGISTER_LIMIT           => 5;
const my $SETTINGS_LIMIT           => 60;
const my $SHORT_WINDOW             => 60;
const my $LONG_WINDOW              => 300;
const my $PROFILE_THREADS          => 10;
const my $PROFILE_REQUESTED        => 5;
const my $COOKIE_NOW               => 1_700_000_000;
const my $COOKIE_AGE               => 31_536_000;

my $access = GPForum::Web::IdentityAccess->new;
my $html   = GPForum::Test::ResponderController->new;
my $json =
  GPForum::Test::ResponderController->new( accept_header => 'application/json',
  );

$access->csrf_failure($html);
is( $html->last_render->{status},
    $HTTP_FORBIDDEN, 'csrf_failure uses HTTP 403' );
is(
    $html->last_render->{text},
    'Bad CSRF token',
    'csrf_failure keeps the login CSRF text'
);

$access->csrf_failure($json);
is(
    $json->last_render->{text},
    'Bad CSRF token',
    'csrf_failure stays text when JSON is requested'
);
ok( !exists $json->last_render->{json},
    'csrf_failure does not emit a JSON error payload' );

$access->rate_limited($html);
is( $html->last_render->{status},
    $HTTP_TOO_MANY, 'rate_limited uses HTTP 429' );
is(
    $html->last_render->{text},
    'Too many requests',
    'rate_limited keeps the shared rate-limit text'
);

$access->rate_limited($json);
is( $json->last_render->{status},
    $HTTP_TOO_MANY, 'JSON rate_limited uses HTTP 429' );
is( $json->last_render->{json}{status},
    'rate_limited', 'JSON rate_limited uses the identity payload' );

$access->system_failure($html);
is( $html->last_render->{status},
    $HTTP_SERVER_ERROR, 'system_failure uses HTTP 500' );
is(
    $html->last_render->{text},
    'internal error',
    'system_failure keeps plaintext internal error'
);

$access->system_failure($json);
is( $json->last_render->{json}{status},
    'error', 'JSON system_failure uses the shared payload' );

$access->service_unavailable($html);
is( $html->last_render->{status},
    $HTTP_SERVICE_UNAVAILABLE, 'service_unavailable uses HTTP 503' );
is(
    $html->last_render->{text},
    'service unavailable',
    'service_unavailable keeps plaintext unavailable copy'
);

$access->service_unavailable($json);
is( $json->last_render->{status},
    $HTTP_SERVICE_UNAVAILABLE, 'JSON service_unavailable uses HTTP 503' );
is( $json->last_render->{json}{status},
    'unavailable', 'JSON service_unavailable uses the shared payload' );

$access->bad_request($html);
is( $html->last_render->{status},
    $HTTP_BAD_REQUEST, 'bad_request uses HTTP 400' );
is(
    $html->last_render->{text},
    'identity request could not be accepted',
    'bad_request keeps the identity plaintext contract'
);

$access->bad_request($json);
is( $json->last_render->{json}{status},
    'invalid', 'JSON bad_request uses the shared invalid payload' );

is_deeply(
    $access->write_rate_input(
        {
            action   => 'identity.login',
            actor_id => '198.51.100.10',
        }
    ),
    {
        action         => 'identity.login',
        actor_id       => '198.51.100.10',
        limit          => $LOGIN_LIMIT,
        scope          => 'identity_http',
        window_seconds => $LONG_WINDOW,
    },
    'write_rate_input uses the login default window'
);

is( $access->write_limit_for('identity.register'),
    $REGISTER_LIMIT, 'write_limit_for caps registration' );
is( $access->write_limit_for('identity.password_change'),
    $PASSWORD_LIMIT, 'write_limit_for caps password changes' );
is( $access->write_limit_for('identity.password_reset'),
    $PASSWORD_LIMIT, 'write_limit_for caps password resets' );
is( $access->write_limit_for('identity.email_change'),
    $PASSWORD_LIMIT, 'write_limit_for caps email changes' );
is( $access->write_limit_for('identity.email_verify'),
    $PASSWORD_LIMIT, 'write_limit_for caps email verification' );
is( $access->write_limit_for('identity.logout'),
    $LOGOUT_LIMIT, 'write_limit_for caps logout' );
is( $access->write_limit_for('identity.settings'),
    $SETTINGS_LIMIT, 'write_limit_for caps settings' );
is( $access->write_limit_for('identity.login'),
    $LOGIN_LIMIT, 'write_limit_for keeps login at the default' );

is( $access->write_window_for('identity.logout'),
    $SHORT_WINDOW, 'write_window_for shortens logout' );
is( $access->write_window_for('identity.settings'),
    $SHORT_WINDOW, 'write_window_for shortens settings' );
is( $access->write_window_for('identity.login'),
    $LONG_WINDOW, 'write_window_for keeps login on the long window' );

is( $access->profile_thread_limit(undef),
    $PROFILE_THREADS, 'profile_thread_limit defaults a missing size' );
is( $access->profile_thread_limit(0),
    $PROFILE_THREADS, 'profile_thread_limit defaults a zero size' );
is( $access->profile_thread_limit($PROFILE_REQUESTED),
    $PROFILE_REQUESTED, 'profile_thread_limit keeps an explicit size' );

is( $access->locale_cookie_name,
    'gpforum_locale', 'locale_cookie_name keeps the preference cookie' );
is( $access->theme_cookie_name,
    'gpforum_theme', 'theme_cookie_name keeps the preference cookie' );
is_deeply(
    $access->preference_cookie_options($COOKIE_NOW),
    {
        expires  => $COOKIE_NOW + $COOKIE_AGE,
        httponly => 1,
        path     => q{/},
        samesite => 'Lax',
    },
    'preference_cookie_options uses a one-year Lax cookie'
);

done_testing();

1;
