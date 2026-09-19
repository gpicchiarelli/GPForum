package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use Digest::SHA qw(sha256_hex);
use GPForum::Service::Identity::Event;
use Test::More;

our $VERSION = '0.001';

const my $SCHEMA_VERSION => 1;
const my $CREATED_AT     => '2026-01-01T00:00:00Z';
const my $IDENTIFIER     => 'giacomo@example.test';
const my $REQUEST_ADDR   => '198.51.100.10';

my $events = GPForum::Service::Identity::Event->new;
my $user   = {
    id       => 'user-1',
    username => 'giacomo',
};

my $envelope = $events->registered_envelope( $user, 'corr-1' );
is( $envelope->{event_type},
    'user.registered', 'registered_envelope uses the registration event type' );
is( $envelope->{aggregate_type},
    'user', 'registered_envelope uses the user aggregate' );
is( $envelope->{schema_version},
    $SCHEMA_VERSION, 'registered_envelope uses schema version 1' );
is( $envelope->{idempotency_key},
    'user.registered:user-1',
    'registered_envelope keys idempotency on the user id' );
is_deeply(
    $envelope->{payload},
    { username => 'giacomo' },
    'registered_envelope keeps the username payload'
);
is( $envelope->{correlation_id},
    'corr-1', 'registered_envelope keeps the supplied correlation id' );

my $audit = $events->registered_audit( $user, 'corr-1' );
is( $audit->{action},
    'user.registered', 'registered_audit uses the registration action' );
is( $audit->{target_id}, 'user-1', 'registered_audit targets the user id' );
is_deeply(
    $audit->{metadata},
    { username => 'giacomo' },
    'registered_audit keeps the username metadata'
);

is_deeply(
    $events->action(
        {
            action      => 'identity.password_reset.requested',
            actor_id    => undef,
            metadata    => undef,
            target_id   => undef,
            target_type => 'identity',
        }
    ),
    {
        action         => 'identity.password_reset.requested',
        actor_id       => undef,
        metadata       => {},
        schema_version => $SCHEMA_VERSION,
        target_id      => undef,
        target_type    => 'identity',
    },
    'action defaults missing metadata to an empty hash'
);

is_deeply(
    $events->action(
        {
            action      => 'identity.email_changed',
            actor_id    => 'user-1',
            metadata    => { email => 'new@example.test' },
            target_id   => 'user-1',
            target_type => 'user',
        }
    ),
    {
        action         => 'identity.email_changed',
        actor_id       => 'user-1',
        metadata       => { email => 'new@example.test' },
        schema_version => $SCHEMA_VERSION,
        target_id      => 'user-1',
        target_type    => 'user',
    },
    'action keeps an explicit metadata hash'
);

my $login = $events->login_request_audit(
    {
        actor_id        => undef,
        created_at      => $CREATED_AT,
        identifier      => $IDENTIFIER,
        request_address => $REQUEST_ADDR,
    }
);
is( $login->{action}, 'identity.login.requested',
    'login_request_audit uses the login request action' );
is( $login->{target_type}, 'identity', 'login_request_audit targets identity' );
is( $login->{created_at},
    $CREATED_AT, 'login_request_audit keeps the supplied created_at' );
is( $login->{schema_version},
    $SCHEMA_VERSION, 'login_request_audit uses schema version 1' );
is( $login->{metadata}{outcome},
    'accepted', 'login_request_audit defaults outcome to accepted' );
is( $login->{metadata}{identifier_hash},
    sha256_hex($IDENTIFIER), 'login_request_audit hashes the identifier' );
isnt( $login->{metadata}{identifier_hash},
    $IDENTIFIER, 'login_request_audit does not keep the raw identifier' );
is(
    $login->{metadata}{request_address_hash},
    sha256_hex($REQUEST_ADDR),
    'login_request_audit hashes the request address'
);

my $rejected = $events->login_request_audit(
    {
        created_at => $CREATED_AT,
        identifier => q{},
        outcome    => 'rejected',
    }
);
is( $rejected->{metadata}{outcome},
    'rejected', 'login_request_audit keeps an explicit outcome' );
ok(
    !defined $rejected->{metadata}{identifier_hash},
    'login_request_audit leaves empty identifiers undefined'
);
ok(
    !defined $rejected->{metadata}{request_address_hash},
    'login_request_audit leaves missing request addresses undefined'
);

my $logout = $events->logout_request_audit(
    {
        actor_id        => 'user-1',
        created_at      => $CREATED_AT,
        request_address => $REQUEST_ADDR,
    }
);
is( $logout->{action}, 'identity.logout.requested',
    'logout_request_audit uses the logout request action' );
is( $logout->{target_type},
    'session', 'logout_request_audit targets the session' );
is( $logout->{actor_id},
    'user-1', 'logout_request_audit keeps the supplied actor' );
is(
    $logout->{metadata}{request_address_hash},
    sha256_hex($REQUEST_ADDR),
    'logout_request_audit hashes the request address'
);
ok( !exists $logout->{metadata}{identifier_hash},
    'logout_request_audit does not include an identifier hash' );

done_testing();

1;
