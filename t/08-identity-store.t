# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Digest::SHA qw(sha256_hex);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::Id;
use GPForum::Test::Schema;
use GPForum::Test::FixedClock;
use GPForum::Test::PostStoreLockDbh;
use GPForum::Test::PostStoreLockStorage;
use GPForum::Test::SessionToken;
use GPForum::Service::Identity::CredentialStore;
use GPForum::Service::Identity::SessionStore;
use GPForum::Service::Identity::Store;
use GPForum::Service::Identity::TokenStore;
use GPForum::Service::Password;

our $VERSION = '0.001';

const my $SESSION_TOKEN    => 'identity-store-probe-token';
const my $EXPECTED_TESTS   => 88;
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
my $revoked_at    = $login_schema->sessions->[0]{revoked_at};
my $revoked_again = $login_store->revoke_session(
    {
        session_id => 'generated-1',
        user_id    => 'user-1',
    }
);
ok( $revoked_again->{ok},      'second logout of the same session succeeds' );
ok( $revoked_again->{skipped}, 'second logout of the same session is skipped' );
is( $login_schema->sessions->[0]{revoked_at},
    $revoked_at, 'second logout keeps the original revocation timestamp' );

my $session_schema = GPForum::Test::Schema->new(
    sessions => [
        {
            session_hash => sha256_hex($SESSION_TOKEN),
            session_id   => 'session-valid',
            user_id      => 'user-1',
            expires_at   => '2026-05-24T12:00:00Z',
            revoked_at   => undef,
            last_seen_at => '2026-05-23T11:00:00Z',
        },
        {
            session_hash => sha256_hex($SESSION_TOKEN),
            session_id   => 'session-expired',
            user_id      => 'user-1',
            expires_at   => '2026-05-23T11:00:00Z',
            revoked_at   => undef,
        },
        {
            session_hash => sha256_hex($SESSION_TOKEN),
            session_id   => 'session-revoked',
            user_id      => 'user-1',
            expires_at   => '2026-05-24T12:00:00Z',
            revoked_at   => '2026-05-23T10:00:00Z',
        },
    ],
);
my $session_store = GPForum::Service::Identity::Store->new(
    clock  => GPForum::Test::FixedClock->new,
    schema => $session_schema,
);
my $valid_session = $session_store->validate_session(
    {
        session_id    => 'session-valid',
        session_token => $SESSION_TOKEN,
        user_id       => 'user-1',
    }
);
ok( $valid_session->{ok}, 'server-side session validation accepts live row' );
is( $session_schema->sessions->[0]{last_seen_at},
    '2026-05-23T12:00:00Z', 'live session updates last_seen_at' );

my $expired_session = $session_store->validate_session(
    {
        session_id    => 'session-expired',
        session_token => $SESSION_TOKEN,
        user_id       => 'user-1',
    }
);
ok( !$expired_session->{ok}, 'expired server-side session is rejected' );
is( $expired_session->{error}, 'expired', 'expired session error is explicit' );
is( $session_schema->sessions->[1]{revoked_at},
    '2026-05-23T12:00:00Z', 'expired session is invalidated server-side' );

my $revoked_session = $session_store->validate_session(
    {
        session_id    => 'session-revoked',
        session_token => $SESSION_TOKEN,
        user_id       => 'user-1',
    }
);
ok( !$revoked_session->{ok}, 'revoked server-side session is rejected' );
is( $revoked_session->{error}, 'revoked', 'revoked session error is explicit' );

# sessions.session_hash used to hold the digest of a token the application
# generated, hashed and then dropped on the floor: nothing ever presented it
# and nothing ever compared it, so the column authenticated nothing while its
# POD said raw tokens went to cookies. The signed cookie now carries the token
# and validation compares it, so a cookie alone is no longer sufficient.
# See docs/QUALITY_PROGRAM.md 2.1.
my $wrong_token = $session_store->validate_session(
    {
        session_id    => 'session-valid',
        session_token => 'a token this session was never issued',
        user_id       => 'user-1',
    }
);
ok( !$wrong_token->{ok}, 'a session token that does not match is rejected' );
is( $wrong_token->{error}, 'invalid_token',
    'the mismatch is reported as an invalid token' );

my $absent_token = $session_store->validate_session(
    { session_id => 'session-valid', user_id => 'user-1' } );
ok( !$absent_token->{ok}, 'a request that presents no token is rejected' );

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
    is( $reset_schema->created_for('EventLog')->[0]{event_type},
        'identity.mail.requested', 'reset request queues identity mail' );
    is_deeply(
        $reset_schema->created_for('EventLog')->[0]{payload},
        {
            kind     => 'password_reset',
            token_id => $reset_schema->identity_tokens->[0]{token_id},
        },
        'mail event payload keeps kind and token id only'
    );
    is(
        $reset_schema->created_for('OutboxMessage')->[0]{payload}{mail}{token},
        'token-1', 'mail outbox payload keeps the raw token until delivery'
    );
    is(
        $reset_schema->created_for('AuditLog')->[1]{action},
        'identity.password_reset.completed',
        'reset completion is audited'
    );

    my $repeat_request = $reset_store->request_password_reset(
        {
            identifier      => 'GIACOMO@example.test',
            request_address => '198.51.100.1',
        }
    );
    ok( $repeat_request->{ok}, 'same-secret reset can issue a new token' );
    my $same_reset = $reset_store->reset_password(
        {
            password => 'new correct horse battery',
            token    => 'token-2',
        }
    );
    ok( $same_reset->{ok},      'same-secret reset succeeds' );
    ok( $same_reset->{skipped}, 'same-secret reset skips credential rotation' );
    is( scalar @{ $reset_schema->created_for('Credential') },
        1, 'same-secret reset does not create another credential' );
    is( $reset_schema->credentials->[0]{revoked_at},
        '2026-05-23T12:00:00Z',
        'same-secret reset keeps the original credential revocation' );
    is( $reset_schema->sessions->[0]{revoked_at},
        '2026-05-23T12:00:00Z', 'same-secret reset still revokes sessions' );

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
        $email_schema->created_for('OutboxMessage')->[0]{payload}{mail}{to},
        'new@example.test',
        'email change mail is addressed to the pending address'
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

subtest
  'password reset rotates an unused token instead of inserting another' => sub {
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

    my $first = $reset_store->request_password_reset(
        {
            identifier      => 'giacomo@example.test',
            request_address => '198.51.100.1',
        }
    );
    ok( $first->{ok}, 'first password reset request is accepted' );
    my $rotated = $reset_store->request_password_reset(
        {
            identifier      => 'giacomo@example.test',
            request_address => '198.51.100.1',
        }
    );
    ok( $rotated->{ok}, 'second password reset request is accepted' );
    ok( $rotated->{token}{rotated},
        'second password reset rotates the unused token' );
    is( $rotated->{token}{raw_token},
        'token-2', 'rotated reset token returns the new raw token' );
    is( scalar @{ $reset_schema->identity_tokens },
        1, 'second password reset does not insert another token row' );
    is( $reset_schema->identity_tokens->[0]{token_hash},
        'hash:token-2', 'rotated reset token replaces the previous hash' );
  };

my $credential_schema = GPForum::Test::Schema->new;
my $credential_store  = GPForum::Service::Identity::CredentialStore->new(
    id_service => GPForum::Test::Id->new,
    schema     => $credential_schema,
);
my $credential = $credential_store->create_password_credential(
    {
        secret_hash => 'argon2id-hash',
        user_id     => 'user-1',
    }
);
is( $credential->{id}, 'generated-1', 'password credential id is generated' );

my $same_credential = $credential_store->create_password_credential(
    {
        secret_hash => 'argon2id-hash-other',
        user_id     => 'user-1',
    }
);
ok( $same_credential->{skipped},
    'already-active password credential skip does not insert a second row' );
is( scalar @{ $credential_schema->created_for('Credential') },
    1, 'already-active password credential does not insert a second row' );

$credential_schema->skip_search_count(1);
my $raced_credential = $credential_store->create_password_credential(
    {
        secret_hash => 'argon2id-hash-race',
        user_id     => 'user-1',
    }
);
ok( $raced_credential->{skipped},
    'unique active password race reuses the credential' );

my $cred_id_schema = GPForum::Test::Schema->new(
    credentials => [
        {
            id          => 'generated-1',
            secret_hash => 'argon2id-other',
            type        => 'password',
            user_id     => 'user-other',
        }
    ]
);
my $cred_id_store = GPForum::Service::Identity::CredentialStore->new(
    id_service => GPForum::Test::Id->new,
    schema     => $cred_id_schema,
);
my $id_credential = $cred_id_store->create_password_credential(
    {
        secret_hash => 'argon2id-hash-new',
        user_id     => 'user-1',
    }
);
is( $id_credential->{id},
    'generated-2', 'unique credential id collision remints the id' );
is( $id_credential->{user_id},
    'user-1', 'unique credential id collision does not return another user' );
ok( !$id_credential->{skipped},
    'unique credential id collision does not skip another credential' );
is( scalar @{ $cred_id_schema->created_for('Credential') },
    1, 'unique credential id collision inserts one retried credential' );

my $leftover_schema = GPForum::Test::Schema->new;
$leftover_schema->resultset('Credential')->create(
    {
        id          => 'generated-1',
        secret_hash => 'argon2id-leftover',
        type        => 'password',
        user_id     => 'user-1',
    }
);
$leftover_schema->skip_search_count(1);
my $leftover_store = GPForum::Service::Identity::CredentialStore->new(
    id_service => GPForum::Test::Id->new,
    schema     => $leftover_schema,
);
my $leftover_credential = $leftover_store->create_password_credential(
    {
        secret_hash => 'argon2id-hash-leftover',
        user_id     => 'user-1',
    }
);
ok( $leftover_credential->{skipped},
    'leftover credential id race reuses this credential' );
is( $leftover_credential->{id},
    'generated-1', 'leftover credential id race keeps this credential' );
is( $leftover_credential->{user_id},
    'user-1', 'leftover credential id race keeps this user' );
is( scalar @{ $leftover_schema->created_for('Credential') },
    1, 'leftover credential id race does not insert a second credential' );

my $hash_schema = GPForum::Test::Schema->new(
    sessions => [
        {
            session_hash => 'hash:token-1',
            session_id   => 'session-seed',
            user_id      => 'user-other',
        }
    ]
);
my $hash_store = GPForum::Service::Identity::SessionStore->new(
    id_service     => GPForum::Test::Id->new,
    schema         => $hash_schema,
    session_tokens => GPForum::Test::SessionToken->new,
);
my $created_session = $hash_store->create_session(
    { id => 'user-1' },
    {
        request_address => '198.51.100.1',
        user_agent      => 'test-agent',
    }
);
is( $created_session->{session}{session_hash},
    'hash:token-2', 'unique session hash collision remints the hash' );
is( $created_session->{session}{user_id},
    'user-1', 'unique session hash collision does not return another user' );
is( $created_session->{session}{session_id},
    'generated-1', 'unique session hash collision keeps a new session id' );
is( scalar @{ $hash_schema->created_for('Session') },
    1, 'unique session hash collision inserts one retried session' );
is( $created_session->{session_token},
    'token-2',
    'and hands back the reminted token, whose hash is the one stored' );

my $id_schema = GPForum::Test::Schema->new(
    sessions => [
        {
            session_hash => 'hash:other',
            session_id   => 'generated-1',
            user_id      => 'user-other',
        }
    ]
);
my $id_store = GPForum::Service::Identity::SessionStore->new(
    id_service     => GPForum::Test::Id->new,
    schema         => $id_schema,
    session_tokens => GPForum::Test::SessionToken->new,
);
my $id_session = $id_store->create_session(
    { id => 'user-1' },
    {
        request_address => '198.51.100.1',
        user_agent      => 'test-agent',
    }
);
is( $id_session->{session}{session_id},
    'generated-2', 'unique session id collision remints the id' );
is( $id_session->{session}{user_id},
    'user-1', 'unique session id collision does not return another user' );
is( $id_session->{session}{session_hash},
    'hash:token-1', 'unique session id collision keeps the minted hash' );
is( scalar @{ $id_schema->created_for('Session') },
    1, 'unique session id collision inserts one retried session' );

my $session_leftover_schema = GPForum::Test::Schema->new;
$session_leftover_schema->resultset('Session')->create(
    {
        session_hash => 'hash:token-1',
        session_id   => 'generated-1',
        user_id      => 'user-1',
    }
);
my $session_leftover_store = GPForum::Service::Identity::SessionStore->new(
    id_service     => GPForum::Test::Id->new,
    schema         => $session_leftover_schema,
    session_tokens => GPForum::Test::SessionToken->new,
);
my $leftover_session = $session_leftover_store->create_session(
    { id => 'user-1' },
    {
        request_address => '198.51.100.1',
        user_agent      => 'test-agent',
    }
);
ok( $leftover_session->{skipped},
    'leftover session id race reuses this session' );
is( $leftover_session->{session}{session_id},
    'generated-1', 'leftover session id race keeps this session' );
is( $leftover_session->{session}{user_id},
    'user-1', 'leftover session id race keeps this user' );
is( scalar @{ $session_leftover_schema->created_for('Session') },
    1, 'leftover session id race does not insert a second session' );

my $issued_schema = GPForum::Test::Schema->new(
    identity_tokens => [
        {
            token_hash => 'hash:token-1',
            token_id   => 'token-seed',
            token_type => 'password_reset',
            used_at    => '2026-05-23T12:00:00Z',
            user_id    => 'user-other',
        }
    ]
);
my $issued_store = GPForum::Service::Identity::TokenStore->new(
    id_service     => GPForum::Test::Id->new,
    schema         => $issued_schema,
    session_tokens => GPForum::Test::SessionToken->new,
);
my $issued_token = $issued_store->create_token(
    {
        token_type  => 'password_reset',
        ttl_seconds => 3600,
        user_id     => 'user-1',
    }
);
is( $issued_token->{token_hash},
    'hash:token-2', 'unique token hash collision remints the hash' );
is( $issued_token->{row}{user_id},
    'user-1', 'unique token hash collision does not return another user' );
ok( !$issued_token->{rotated},
    'unique token hash collision does not rotate another token' );
is( scalar @{ $issued_schema->created_for('IdentityToken') },
    1, 'unique token hash collision inserts one retried token' );

my $token_id_schema = GPForum::Test::Schema->new(
    identity_tokens => [
        {
            token_hash => 'hash:other',
            token_id   => 'generated-1',
            token_type => 'password_reset',
            used_at    => '2026-05-23T12:00:00Z',
            user_id    => 'user-other',
        }
    ]
);
my $token_id_store = GPForum::Service::Identity::TokenStore->new(
    id_service     => GPForum::Test::Id->new,
    schema         => $token_id_schema,
    session_tokens => GPForum::Test::SessionToken->new,
);
my $id_issued = $token_id_store->create_token(
    {
        token_type  => 'password_reset',
        ttl_seconds => 3600,
        user_id     => 'user-1',
    }
);
is( $id_issued->{token_id},
    'generated-2', 'unique token id collision remints the id' );
is( $id_issued->{row}{user_id},
    'user-1', 'unique token id collision does not return another user' );
is( $id_issued->{token_hash},
    'hash:token-1', 'unique token id collision keeps the minted hash' );
is( scalar @{ $token_id_schema->created_for('IdentityToken') },
    1, 'unique token id collision inserts one retried token' );

my $token_leftover_schema = GPForum::Test::Schema->new;
$token_leftover_schema->resultset('IdentityToken')->create(
    {
        token_hash => 'hash:token-1',
        token_id   => 'generated-1',
        token_type => 'password_reset',
        user_id    => 'user-1',
    }
);
my $token_leftover_store = GPForum::Service::Identity::TokenStore->new(
    id_service     => GPForum::Test::Id->new,
    schema         => $token_leftover_schema,
    session_tokens => GPForum::Test::SessionToken->new,
);
my $leftover_token = $token_leftover_store->create_token(
    {
        token_type  => 'password_reset',
        ttl_seconds => 3600,
        user_id     => 'user-1',
    }
);
ok( $leftover_token->{skipped}, 'leftover token id race reuses this token' );
is( $leftover_token->{token_id},
    'generated-1', 'leftover token id race keeps this token' );
is( $leftover_token->{row}{user_id},
    'user-1', 'leftover token id race keeps this user' );
is( scalar @{ $token_leftover_schema->created_for('IdentityToken') },
    1, 'leftover token id race does not insert a second token' );

1;
