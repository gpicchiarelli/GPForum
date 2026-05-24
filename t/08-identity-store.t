package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::Id;
use GPForum::Test::Schema;
use GPForum::Test::FixedClock;
use GPForum::Service::Identity::Store;
use GPForum::Service::Password;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 33;

plan tests => $EXPECTED_TESTS;

my $schema = GPForum::Test::Schema->new;
my $store  = GPForum::Service::Identity::Store->new(
    schema     => $schema,
    id_service => GPForum::Test::Id->new,
);

my $registration = {
    user => {
        id               => 'user-1',
        username         => 'giacomo',
        display_name     => 'Giacomo Picchiarelli',
        email_normalized => 'giacomo@example.test',
        password_hash    => 'argon2id-hash',
        status           => 'pending',
        trust_level      => 0,
    },
    credential => {
        type        => 'password',
        secret_hash => 'argon2id-hash',
    },
};

my $created = $store->create_registration($registration);

ok( $created->{ok}, 'registration is persisted' );
is( scalar @{ $schema->created_for('User') }, 1, 'user row is created' );
is( scalar @{ $schema->created_for('Credential') },
    1, 'credential row is created' );
is( scalar @{ $schema->created_for('EventLog') }, 1, 'event row is created' );
is( scalar @{ $schema->created_for('AuditLog') }, 1, 'audit row is created' );
is( $schema->created_for('Credential')->[0]{user_id},
    'user-1', 'credential is linked to user' );
is( $schema->created_for('EventLog')->[0]{event_type},
    'user.registered', 'registration event is recorded' );
is( $schema->created_for('EventLog')->[0]{schema_version},
    1, 'registration event is versioned' );
is( $schema->created_for('EventLog')->[0]{idempotency_key},
    'user.registered:user-1', 'registration event has idempotency key' );
is( $schema->created_for('AuditLog')->[0]{action},
    'user.registered', 'registration audit is recorded' );
is(
    $schema->created_for('AuditLog')->[0]{correlation_id},
    $schema->created_for('EventLog')->[0]{correlation_id},
    'event and audit share a correlation id'
);
is( $schema->transaction_count, 1, 'registration uses one transaction' );

my $password_service = GPForum::Service::Password->new;
my $login_schema     = GPForum::Test::Schema->new(
    users => [
        {
            id               => 'user-1',
            username         => 'giacomo',
            display_name     => 'Giacomo Picchiarelli',
            email_normalized => 'giacomo@example.test',
            status           => 'active',
        },
    ],
    credentials => [
        {
            user_id     => 'user-1',
            type        => 'password',
            secret_hash =>
              $password_service->hash_password('correct horse battery staple'),
            created_at => '2026-05-23T12:00:00Z',
            revoked_at => undef,
        },
    ],
);
my $login_store = GPForum::Service::Identity::Store->new(
    schema     => $login_schema,
    id_service => GPForum::Test::Id->new,
);

my $login = $login_store->authenticate_login(
    {
        identifier      => 'GIACOMO@example.test',
        password        => 'correct horse battery staple',
        request_address => '198.51.100.10',
        user_agent      => 'TestAgent',
    }
);

ok( $login->{ok}, 'valid login is accepted' );
is( $login->{user_id},    'user-1', 'login returns authenticated user id' );
is( $login->{session_id}, 'generated-1', 'login creates session id' );
is( scalar @{ $login_schema->created_for('Session') },
    1, 'login persists a server-side session' );
isnt( $login_schema->created_for('Session')->[0]{ip_hash},
    '198.51.100.10', 'login stores hashed request address' );
is( $login_schema->transaction_count,
    1, 'login session creation uses one transaction' );

my $failed_login = $login_store->authenticate_login(
    {
        identifier => 'giacomo',
        password   => 'wrong password',
    }
);
ok( !$failed_login->{ok}, 'wrong password is rejected' );
is( $failed_login->{error},
    'invalid_credentials', 'login failure remains non-enumerative' );

my $revoked = $login_store->revoke_session(
    {
        session_id => 'generated-1',
        user_id    => 'user-1',
    }
);
ok( $revoked->{ok}, 'logout revokes server-side session' );
ok(
    $login_schema->sessions->[0]{revoked_at},
    'revoked session records revocation timestamp'
);

my $session_schema = GPForum::Test::Schema->new(
    sessions => [
        {
            session_id   => 'session-valid',
            user_id      => 'user-1',
            expires_at   => '2026-05-24T12:00:00Z',
            revoked_at   => undef,
            last_seen_at => '2026-05-23T11:00:00Z',
        },
        {
            session_id => 'session-expired',
            user_id    => 'user-1',
            expires_at => '2026-05-23T11:00:00Z',
            revoked_at => undef,
        },
        {
            session_id => 'session-revoked',
            user_id    => 'user-1',
            expires_at => '2026-05-24T12:00:00Z',
            revoked_at => '2026-05-23T10:00:00Z',
        },
    ],
);
my $session_store = GPForum::Service::Identity::Store->new(
    clock  => GPForum::Test::FixedClock->new,
    schema => $session_schema,
);
my $valid_session = $session_store->validate_session(
    { session_id => 'session-valid', user_id => 'user-1' } );
ok( $valid_session->{ok}, 'server-side session validation accepts live row' );
is( $session_schema->sessions->[0]{last_seen_at},
    '2026-05-23T12:00:00Z', 'live session updates last_seen_at' );

my $expired_session = $session_store->validate_session(
    { session_id => 'session-expired', user_id => 'user-1' } );
ok( !$expired_session->{ok}, 'expired server-side session is rejected' );
is( $expired_session->{error}, 'expired', 'expired session error is explicit' );
is( $session_schema->sessions->[1]{revoked_at},
    '2026-05-23T12:00:00Z', 'expired session is invalidated server-side' );

my $revoked_session = $session_store->validate_session(
    { session_id => 'session-revoked', user_id => 'user-1' } );
ok( !$revoked_session->{ok}, 'revoked server-side session is rejected' );
is( $revoked_session->{error}, 'revoked', 'revoked session error is explicit' );

my $duplicate_schema = GPForum::Test::Schema->new(
    existing_usernames => { giacomo                => 1 },
    existing_emails    => { 'giacomo@example.test' => 1 },
);
my $duplicate_store = GPForum::Service::Identity::Store->new(
    schema     => $duplicate_schema,
    id_service => GPForum::Test::Id->new,
);

my $duplicate = $duplicate_store->create_registration($registration);

ok( !$duplicate->{ok}, 'duplicate registration is rejected' );
is(
    $duplicate->{errors}{username},
    'username is already registered',
    'duplicate username is reported'
);
is(
    $duplicate->{errors}{email},
    'email is already registered',
    'duplicate email is reported'
);
is( $duplicate_schema->transaction_count,
    0, 'duplicate registration does not open transaction' );

1;
