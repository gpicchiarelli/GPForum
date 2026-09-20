package main;

use strict;
use warnings;

use Test::More;

use lib 'lib';

use GPForum::Web::ErrorPayload;

our $VERSION = '0.001';

my $payload = GPForum::Web::ErrorPayload->new;

is_deeply(
    $payload->bad_request(
        error  => 'The submitted forum request was invalid.',
        errors => { title => 'title is required' },
        title  => 'Invalid request',
    ),
    {
        error  => 'The submitted forum request was invalid.',
        errors => { title => 'title is required' },
        status => 'invalid',
        title  => 'Invalid request',
    },
    'bad request payload preserves existing JSON shape'
);

is_deeply(
    $payload->csrf_failure,
    {
        error  => 'Bad CSRF token',
        status => 'forbidden',
        title  => 'Forbidden',
    },
    'csrf payload is centralized'
);

is( $payload->csrf_text, 'Bad CSRF token', 'csrf text remains stable' );

is_deeply(
    $payload->unauthorized,
    {
        error  => 'authentication required',
        status => 'unauthorized',
        title  => 'Authentication required',
    },
    'unauthorized payload is centralized'
);

is_deeply(
    $payload->forbidden( error => 'attachment is not available' ),
    {
        error  => 'attachment is not available',
        status => 'forbidden',
        title  => 'Forbidden',
    },
    'forbidden payload supports route-specific messages'
);

is_deeply(
    $payload->not_found( error => 'thread not found' ),
    {
        error  => 'thread not found',
        status => 'not_found',
        title  => 'Not found',
    },
    'not-found payload supports route-specific messages'
);

is_deeply(
    $payload->rate_limited,
    {
        error  => 'too many requests',
        status => 'rate_limited',
        title  => 'Too many requests',
    },
    'rate-limit payload is centralized'
);

is_deeply(
    $payload->rate_limited(
        error => 'rate limit exceeded',
        title => 'Rate limited',
    ),
    {
        error  => 'rate limit exceeded',
        status => 'rate_limited',
        title  => 'Rate limited',
    },
    'rate-limit payload preserves route-specific wording'
);

is(
    $payload->rate_limited_text,
    'Too many requests',
    'rate-limit text remains stable'
);

is_deeply(
    $payload->system_failure,
    {
        error  => 'internal error',
        status => 'error',
        title  => 'Internal error',
    },
    'system failure payload is centralized'
);

is_deeply(
    $payload->unavailable,
    {
        error  => 'service unavailable',
        status => 'unavailable',
        title  => 'Service unavailable',
    },
    'unavailable payload is centralized'
);

is_deeply(
    $payload->conflict(
        error  => 'retention_hold_active',
        status => 'blocked',
        title  => 'Privacy action blocked',
    ),
    {
        error  => 'retention_hold_active',
        status => 'blocked',
        title  => 'Privacy action blocked',
    },
    'conflict payload supports privacy blocked shape'
);

is_deeply(
    $payload->identity_rate_limited,
    {
        error  => 'too many requests',
        status => 'rate_limited',
    },
    'identity rate-limit payload preserves legacy shape'
);

is_deeply(
    $payload->identity_invalid_login,
    {
        error  => 'login request could not be accepted',
        status => 'unauthorized',
    },
    'identity invalid-login payload preserves legacy shape'
);

is_deeply(
    $payload->identity_profile_not_found,
    {
        error  => 'profile not found',
        status => 'not_found',
    },
    'identity profile not-found payload preserves legacy shape'
);

done_testing();
