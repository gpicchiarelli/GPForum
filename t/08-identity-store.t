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
use GPForum::Test::PostStoreLockDbh;
use GPForum::Test::PostStoreLockStorage;
use GPForum::Test::SessionToken;
use GPForum::Service::Identity::Store;
use GPForum::Service::Password;

our $VERSION = '0.001';

const my $EXPECTED_TESTS   => 44;
const my $FIXED_2026_EPOCH => 1_779_537_600;

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
is( scalar @{ $schema->created_for('OutboxMessage') },
    1, 'registration queues outbox message' );
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
            preferred_locale => 'en',
            preferred_theme  => 'default',
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

my $locale_update = $login_store->update_preferred_locale(
    {
        user_id          => 'user-1',
        preferred_locale => 'it',
    }
);
ok( $locale_update->{ok}, 'preferred locale update succeeds' );
is( $login_schema->users->[0]{preferred_locale},
    'it', 'preferred locale is persisted on the user row' );
is(
    $login_schema->users->[0]{updated_at},
    $login_store->clock->now_iso8601,
    'preferred locale update refreshes user updated_at'
);

my $theme_update = $login_store->update_preferred_theme(
    {
        user_id         => 'user-1',
        preferred_theme => 'high_contrast',
    }
);
ok( $theme_update->{ok}, 'preferred theme update succeeds' );
is( $login_schema->users->[0]{preferred_theme},
    'high_contrast', 'preferred theme is persisted on the user row' );
is(
    $login_schema->users->[0]{updated_at},
    $login_store->clock->now_iso8601,
    'preferred theme update refreshes user updated_at'
);
is(
    $login_store->preferred_theme_for_user( { user_id => 'user-1' } )
      ->{preferred_theme},
    'high_contrast',
    'preferred theme can be read back through identity store'
);

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

subtest 'password reset token is one-time, locked, and audited' => sub {
    my $lock_dbh     = GPForum::Test::PostStoreLockDbh->new;
    my $reset_schema = GPForum::Test::Schema->new(
        credentials => [
            {
                user_id     => 'user-1',
                type        => 'password',
                secret_hash => $password_service->hash_password(
                    'correct horse battery staple'),
                revoked_at => undef,
            },
        ],
        sessions => [
            {
                session_id => 'session-1',
                user_id    => 'user-1',
                revoked_at => undef,
            },
        ],
        storage => GPForum::Test::PostStoreLockStorage->new(
            dbh => $lock_dbh,
        ),
        users => [
            {
                id               => 'user-1',
                username         => 'giacomo',
                display_name     => 'Giacomo Picchiarelli',
                email_normalized => 'giacomo@example.test',
                status           => 'active',
            },
        ],
    );
    my $reset_store = GPForum::Service::Identity::Store->new(
        clock => GPForum::Test::FixedClock->new(
            epoch => $FIXED_2026_EPOCH
        ),
        id_service     => GPForum::Test::Id->new,
        schema         => $reset_schema,
        session_tokens => GPForum::Test::SessionToken->new,
    );

    my $request = $reset_store->request_password_reset(
        {
            identifier      => 'GIACOMO@example.test',
            request_address => '198.51.100.1',
        }
    );
    ok( $request->{ok}, 'password reset request is accepted' );
    is( $request->{token}{raw_token},
        'token-1', 'raw reset token is returned only by service boundary' );
    is( $reset_schema->identity_tokens->[0]{token_hash},
        'hash:token-1', 'only token hash is stored' );
    is( $reset_schema->identity_tokens->[0]{expires_at},
        '2026-05-23T13:00:00Z', 'reset token expires after one hour' );

    my $reset = $reset_store->reset_password(
        {
            password => 'new correct horse battery',
            token    => 'token-1',
        }
    );
    ok( $reset->{ok}, 'password reset succeeds with valid token' );
    my ($token_lock) =
      grep { $_->{sql} =~ m/FOR [ ] UPDATE/msx } @{ $lock_dbh->calls };
    is(
        $token_lock->{sql},
        'SELECT token_id FROM identity_tokens WHERE token_hash = ? FOR UPDATE',
        'reset locks token row before consuming it'
    );
    is_deeply( $token_lock->{bind},
        ['hash:token-1'], 'reset lock targets token hash' );
    is( $reset_schema->identity_tokens->[0]{used_at},
        '2026-05-23T12:00:00Z', 'reset marks token used' );
    is( $reset_schema->credentials->[0]{revoked_at},
        '2026-05-23T12:00:00Z', 'reset revokes old password credential' );
    is( scalar @{ $reset_schema->created_for('Credential') },
        1, 'reset creates replacement password credential' );
    is( $reset_schema->sessions->[0]{revoked_at},
        '2026-05-23T12:00:00Z', 'reset revokes existing sessions' );
    is(
        $reset_schema->created_for('AuditLog')->[0]{action},
        'identity.password_reset.requested',
        'reset request is audited'
    );
    is(
        $reset_schema->created_for('AuditLog')->[1]{action},
        'identity.password_reset.completed',
        'reset completion is audited'
    );

    my $reused = $reset_store->reset_password(
        {
            password => 'another correct horse',
            token    => 'token-1',
        }
    );
    ok( !$reused->{ok}, 'used reset token is rejected' );
    is( $reused->{error}, 'token_used', 'used token error is explicit' );
    is( scalar @{ $reset_schema->created_for('Credential') },
        1, 'used reset token does not create another credential' );
};

subtest 'change password verifies current credential and audits success' =>
  sub {
    my $password_schema = GPForum::Test::Schema->new(
        credentials => [
            {
                user_id     => 'user-1',
                type        => 'password',
                secret_hash => $password_service->hash_password(
                    'correct horse battery staple'),
                revoked_at => undef,
            },
        ],
        users => [
            {
                id               => 'user-1',
                username         => 'giacomo',
                display_name     => 'Giacomo Picchiarelli',
                email_normalized => 'giacomo@example.test',
                status           => 'active',
            },
        ],
    );
    my $password_store = GPForum::Service::Identity::Store->new(
        clock => GPForum::Test::FixedClock->new(
            epoch => $FIXED_2026_EPOCH
        ),
        id_service => GPForum::Test::Id->new,
        schema     => $password_schema,
    );

    my $wrong = $password_store->change_password(
        {
            current_password => 'wrong password',
            new_password     => 'new correct horse battery',
            user_id          => 'user-1',
        }
    );
    ok( !$wrong->{ok}, 'wrong current password is rejected' );
    is( $wrong->{error},
        'invalid_current_password', 'current password error is explicit' );

    my $changed = $password_store->change_password(
        {
            current_password => 'correct horse battery staple',
            new_password     => 'new correct horse battery',
            user_id          => 'user-1',
        }
    );
    ok( $changed->{ok}, 'password change succeeds' );
    is( $password_schema->credentials->[0]{revoked_at},
        '2026-05-23T12:00:00Z', 'old credential is revoked' );
    is( scalar @{ $password_schema->created_for('Credential') },
        1, 'new credential is created' );
    is( $password_schema->created_for('AuditLog')->[0]{action},
        'identity.password.changed', 'password change is audited' );
  };

subtest 'email change requires confirmation token and prevents replay' => sub {
    my $email_schema = GPForum::Test::Schema->new(
        users => [
            {
                id               => 'user-1',
                username         => 'giacomo',
                display_name     => 'Giacomo Picchiarelli',
                email_normalized => 'giacomo@example.test',
                status           => 'active',
            },
            {
                id               => 'user-2',
                username         => 'other',
                display_name     => 'Other User',
                email_normalized => 'other@example.test',
                status           => 'active',
            },
        ],
    );
    my $email_store = GPForum::Service::Identity::Store->new(
        clock => GPForum::Test::FixedClock->new(
            epoch => $FIXED_2026_EPOCH
        ),
        id_service     => GPForum::Test::Id->new,
        schema         => $email_schema,
        session_tokens => GPForum::Test::SessionToken->new,
    );

    my $duplicate_email = $email_store->request_email_change(
        {
            email   => 'other@example.test',
            user_id => 'user-1',
        }
    );
    ok( !$duplicate_email->{ok}, 'duplicate email change is rejected' );
    is( $duplicate_email->{error},
        'email_already_registered', 'duplicate email error is explicit' );

    my $request = $email_store->request_email_change(
        {
            email           => 'NEW@example.test',
            request_address => '198.51.100.1',
            user_id         => 'user-1',
        }
    );
    ok( $request->{ok}, 'email change request succeeds' );
    is( $email_schema->identity_tokens->[0]{email_normalized},
        'new@example.test', 'pending email is normalized in token row' );
    is( $email_schema->identity_tokens->[0]{token_hash},
        'hash:token-1', 'email confirmation stores token hash' );

    my $confirmed =
      $email_store->confirm_email_change( { token => 'token-1' } );
    ok( $confirmed->{ok}, 'email confirmation succeeds' );
    is( $email_schema->users->[0]{email_normalized},
        'new@example.test', 'confirmed email is persisted' );
    is( $email_schema->users->[0]{email_verified_at},
        '2026-05-23T12:00:00Z', 'confirmed email is verified' );
    is( $email_schema->identity_tokens->[0]{used_at},
        '2026-05-23T12:00:00Z', 'email token is consumed' );
    is(
        $email_schema->created_for('AuditLog')->[0]{action},
        'identity.email_change.requested',
        'email change request is audited'
    );
    is(
        $email_schema->created_for('AuditLog')->[1]{action},
        'identity.email_change.confirmed',
        'email confirmation is audited'
    );

    my $reused = $email_store->confirm_email_change( { token => 'token-1' } );
    ok( !$reused->{ok}, 'used email token is rejected' );
    is( $reused->{error}, 'token_used', 'used email token error is explicit' );
};

1;
