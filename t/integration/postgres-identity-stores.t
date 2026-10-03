# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Digest::SHA   qw(sha256_hex);
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(decode_json);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Infrastructure::Id;
use GPForum::Schema;
use GPForum::Service::Identity::AuthStore;
use GPForum::Service::Identity::CredentialStore;
use GPForum::Service::Identity::SessionStore;
use GPForum::Service::Identity::Store;
use GPForum::Service::Identity::Support;
use GPForum::Service::Identity::TokenStore;
use GPForum::Test::FixedClock;
use GPForum::Test::PgDatabase;
use GPForum::Test::RecordingPassword;
use GPForum::Test::ScriptedId;
use GPForum::Test::SessionToken;

our $VERSION = '0.001';
our $TODO;

const my $NOW         => '2026-05-23T12:00:00Z';
const my $HALF_PAST   => '2026-05-23T12:30:00Z';
const my $LATER       => '2026-05-23T13:00:00Z';
const my $LATEST      => '2026-05-23T14:00:00Z';
const my $SEEN        => '2026-05-23T11:00:00Z';
const my $REVOKED     => '2026-05-23T10:00:00Z';
const my $EARLY       => '2026-05-23T09:00:00Z';
const my $TOMORROW    => '2026-05-24T12:00:00Z';
const my $SESSION_END => '2026-06-22T12:00:00Z';
const my $HOUR        => 3_600;

const my $PASSWORD       => 'correct horse battery staple';
const my $NEW_PASSWORD   => 'new correct horse battery';
const my $OTHER_PASSWORD => 'another correct horse';
const my $NEWER_PASSWORD => 'a different sufficiently long password';
const my $ADDRESS        => '198.51.100.10';
const my $AGENT          => 'TestAgent';

# The defects this test found in code outside its reach, pinned where they
# show (quality program 5.1). SessionStore looks a session up with find on
# its id and the member's, and DBIx::Class's find keeps only the columns of
# a unique constraint the values satisfy: the primary key, so the member is
# dropped from the WHERE clause. The fake ORM matched every column it was
# given.
const my $CREDENTIAL_TODO =>
  'CredentialStore leaves created_at to the database clock';
const my $SESSION_TODO =>
  'SessionStore finds a session by its id alone, whoever presents it';

# Each collision case mints its own series of deterministic session tokens,
# so the hashes one case stores never collide with another case's.
const my %SERIES => (
    session_hash     => 0,
    session_id       => 10,
    session_leftover => 20,
    token_hash       => 30,
    token_id         => 40,
    token_leftover   => 50,
);

const my $USER_SQL => join q{ },
  'INSERT INTO users (id, username, display_name, email_normalized,',
  'password_hash, status, email_verified_at) VALUES (?, ?, ?, ?, ?, ?, ?)';
const my $CREDENTIAL_SQL => join q{ },
  'INSERT INTO credentials (id, user_id, type, secret_hash, created_at)',
  q{VALUES (?, ?, 'password', ?, ?)};
const my $SESSION_SQL => join q{ },
  'INSERT INTO sessions (session_id, user_id, session_hash, created_at,',
  'last_seen_at, expires_at, revoked_at) VALUES (?, ?, ?, ?, ?, ?, ?)';
const my $TOKEN_SQL => join q{ },
  'INSERT INTO identity_tokens (token_id, user_id, token_type, token_hash,',
  'email_normalized, created_at, expires_at, used_at)',
  'VALUES (?, ?, ?, ?, ?, ?, ?, ?)';
const my $TAKE_EMAIL_SQL =>
  'UPDATE users SET email_normalized = ? WHERE id = ?';

# A timestamp as the clock writes it, whatever zone the server returns it in.
const my $UTC_SQL => join q{ },
  q{SELECT to_char(?::timestamptz AT TIME ZONE 'UTC',},
  q{'YYYY-MM-DD"T"HH24:MI:SS"Z"')};
const my $USER_ROW_SQL   => 'SELECT * FROM users WHERE id = ?';
const my $USER_NAMED_SQL => 'SELECT id FROM users WHERE username = ?';
const my $USER_EMAIL_SQL =>
  'SELECT count(*) FROM users WHERE email_normalized = ?';
const my $SESSION_ROW_SQL => 'SELECT * FROM sessions WHERE session_id = ?';
const my $TOKEN_ROW_SQL   => 'SELECT * FROM identity_tokens WHERE token_id = ?';
const my $USER_TOKEN_SQL  => 'SELECT * FROM identity_tokens WHERE user_id = ?';
const my $USER_TOKENS_SQL =>
  'SELECT count(*) FROM identity_tokens WHERE user_id = ?';
const my $CREDENTIAL_ROW_SQL => 'SELECT * FROM credentials WHERE id = ?';
const my $USER_CREDENTIALS_SQL =>
  'SELECT count(*) FROM credentials WHERE user_id = ?';
const my $ACTIVE_CREDENTIAL_SQL =>
  'SELECT * FROM credentials WHERE user_id = ? AND revoked_at IS NULL';
const my $ACTIVE_CREDENTIALS_SQL => join q{ },
  'SELECT count(*) FROM credentials',
  'WHERE user_id = ? AND revoked_at IS NULL';
const my $USER_SESSION_SQL => 'SELECT * FROM sessions WHERE user_id = ?';
const my $USER_SESSIONS_SQL =>
  'SELECT count(*) FROM sessions WHERE user_id = ?';
const my $EVENT_SQL => 'SELECT * FROM event_log WHERE aggregate_id = ?';
const my $USER_EVENTS_SQL =>
  'SELECT count(*) FROM event_log WHERE aggregate_id = ?';
const my $OUTBOX_SQL => 'SELECT * FROM outbox_messages WHERE event_id = ?';
const my $AUDIT_SQL  => 'SELECT * FROM audit_log WHERE target_id = ?';
const my $USER_AUDITS_SQL => join q{ },
  'SELECT count(*) FROM audit_log WHERE target_id = ? AND action = ?';
const my $AUDIT_ACTION_SQL => join q{ },
  'SELECT * FROM audit_log WHERE target_id = ? AND action = ?';
const my $ANONYMOUS_AUDIT_SQL => join q{ },
  'SELECT * FROM audit_log WHERE target_id IS NULL AND action = ?',
  q{AND metadata ->> 'identifier_hash' = ?};
const my $MAILS_SQL => join q{ },
  'SELECT o.payload AS outbox, e.payload AS event FROM outbox_messages o',
  'JOIN event_log e ON e.event_id = o.event_id',
  q{WHERE e.event_type = 'identity.mail.requested' AND e.aggregate_id = ?},
  'ORDER BY o.created_at, o.outbox_id';
const my $ALL_MAILS_SQL => join q{ },
  'SELECT count(*) FROM event_log',
  q{WHERE event_type = 'identity.mail.requested'};
const my $LOCK_SQL => join q{ },
  'SELECT token_id FROM identity_tokens WHERE token_id = ?',
  'FOR UPDATE NOWAIT';
const my $LOCK_NOT_AVAILABLE => '55P03';

# The transaction that last wrote a row: a row that keeps it was not
# written since, not even with the values it already held.
const my %VERSION_SQL => (
    session => 'SELECT xmin::text FROM sessions WHERE session_id = ?',
    user    => 'SELECT xmin::text FROM users WHERE id = ?',
);

# The statement each race waits for: the rival commits just before the
# store's own reaches PostgreSQL.
const my %BEFORE => (
    'credential insert' => qr/\A INSERT [ ] INTO [ ] credentials [ ]/msx,
    'token read'        =>
      qr/\A SELECT [ ] [^;]+? [ ] FROM [ ] identity_tokens [ ] me [ ]/msx,
    'user insert' => qr/\A INSERT [ ] INTO [ ] users [ ]/msx,
    'user update' => qr/\A UPDATE [ ] users [ ] SET [ ]/msx,
);

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run against PostgreSQL';
}

# The identity stores on PostgreSQL: registration, login, logout and
# sessions, password reset and change, email change and verification,
# preferences, and the credential, session and token rows beneath them.
# These ran on a fake ORM in t/08 and t/109 to t/112, whose rows had no
# types, no constraints and no transactions: three sessions shared one hash,
# a credential was revoked before it was created, an id was 'user-1', and a
# store's result read as a hash where DBIx::Class hands back a row. A race
# was a look-up told to miss; here a rival connection commits the competing
# row between the store's look-up and its write, and PostgreSQL raises the
# conflict the store recovers from.
my $database = GPForum::Test::PgDatabase->fresh;
my $identity = _context($database);

_registration($identity);
_duplicate_registration($identity);
_registration_race($identity);
_registration_id_collision($identity);
_registration_id_race($identity);
_login($identity);
_authentication($identity);
_logout($identity);
_session_validation($identity);
_locale_preference($identity);
_theme_preference($identity);
_timezone_preference($identity);
_password_reset($identity);
_password_reset_unknown($identity);
_password_reset_rotation($identity);
_password_change($identity);
_email_change($identity);
_email_change_refusals($identity);
_email_change_race($identity);
_email_verification($identity);
_credential_rows($identity);
_credential_race($identity);
_credential_id_collision($identity);
_credential_id_race($identity);
_session_hash_collision($identity);
_session_id_collision($identity);
_session_id_leftover($identity);
_token_hash_collision($identity);
_token_id_collision($identity);
_token_id_leftover($identity);

$identity->{rival}->storage->disconnect;

done_testing();

sub _context {
    my ($database_arg) = @_;

    my $password = GPForum::Test::RecordingPassword->new;
    my $ctx      = {
        clock => GPForum::Test::FixedClock->new(
            epoch   => _epoch($NOW),
            iso8601 => $NOW,
        ),
        dbh      => $database_arg->dbh,
        ids      => GPForum::Infrastructure::Id->new,
        password => $password,
        rival    => _rival_schema($database_arg),
        schema   => $database_arg->schema,
        serial   => 0,
    };

    # One Argon2 hash for every member's password: each costs what a login
    # does, and none of these cases is about the hash itself.
    $ctx->{secret} = $password->hash_password($PASSWORD);

    return $ctx;
}

# A second connection to the same database: the concurrent request.
sub _rival_schema {
    my ($database_arg) = @_;

    local $ENV{GPFORUM_DATABASE_DSN} = $database_arg->dsn;

    return GPForum::Schema->connect_from_config(
        GPForum::Config->from_environment );
}

# The account, its password, its event, the event's outbox message and its
# audit row, in one transaction.
sub _registration {
    my ($ctx) = @_;

    my $id = $ctx->{ids}->uuid;
    my ( $created, $transactions ) = _transactions(
        $ctx,
        sub {
            return _identity($ctx)
              ->create_registration(
                _registration_input( $ctx, $id, 'giacomo' ) );
        }
    );
    ok( $created->{ok}, 'registration is persisted' );
    my $user = _row( $ctx, $USER_ROW_SQL, $id );
    is( $user->{username}, 'giacomo', 'user row is created' );
    is( $user->{status},   'pending', 'as a pending account' );
    is( $user->{password_hash},
        $ctx->{secret}, 'which copies the credential hash' );
    is( _row( $ctx, $ACTIVE_CREDENTIAL_SQL, $id )->{secret_hash},
        $ctx->{secret}, 'credential row is created and linked to the user' );

    my $event = _row( $ctx, $EVENT_SQL, $id );
    is( $event->{event_type}, 'user.registered',
        'registration event is recorded' );
    is( $event->{schema_version}, 1, 'registration event is versioned' );
    is( $event->{idempotency_key},
        "user.registered:$id", 'registration event has idempotency key' );
    ok( _row( $ctx, $OUTBOX_SQL, $event->{event_id} )->{outbox_id},
        'registration queues outbox message' );
    my $audit = _row( $ctx, $AUDIT_SQL, $id );
    is( $audit->{action}, 'user.registered', 'registration audit is recorded' );
    is(
        $audit->{correlation_id},
        $event->{correlation_id},
        'event and audit share a correlation id'
    );

    is( $transactions, 1, 'registration uses one transaction' );

    return;
}

# Taken username and address: refused from the look-ups alone, before a
# transaction is opened or a row written.
sub _duplicate_registration {
    my ($ctx) = @_;

    _member( $ctx, 'taken' );
    my $input = _registration_input( $ctx, $ctx->{ids}->uuid, 'taken' );
    my ( $answer, $transactions ) = _transactions(
        $ctx,
        sub {
            return [
                _statements(
                    $ctx,
                    sub {
                        return _identity($ctx)->create_registration($input);
                    }
                )
            ];
        }
    );
    my ( $duplicate, $statements ) = @{$answer};
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
    is( $transactions, 0, 'duplicate registration does not open transaction' );
    is_deeply( [ grep { !/\A SELECT [ ]/msx } @{$statements} ],
        [], 'and sends nothing but look-ups' );

    return;
}

# The rival registers the same username and address between the store's
# look-ups, which found neither, and its insert: the unique constraints
# refuse the second account, the store answers with the duplicate errors,
# and nothing of the refused registration survives its transaction.
sub _registration_race {
    my ($ctx) = @_;

    my $attempted = $ctx->{ids}->uuid;
    my $rival_id  = $ctx->{ids}->uuid;
    my ( $raced, $transactions ) = _transactions(
        $ctx,
        sub {
            return _before(
                $ctx,
                'user insert',
                sub {
                    my ($rival) = @_;
                    _rival_user( $rival, $rival_id, 'racer' );
                    return;
                },
                sub {
                    return _identity($ctx)
                      ->create_registration(
                        _registration_input( $ctx, $attempted, 'racer' ) );
                }
            );
        }
    );
    ok( !$raced->{ok}, 'registration unique race is rejected' );
    is( $transactions, 1, 'registration unique race opens one transaction' );
    is(
        $raced->{errors}{username},
        'username is already registered',
        'registration unique race reports a duplicate username'
    );
    is(
        $raced->{errors}{email},
        'email is already registered',
        'registration unique race reports a duplicate email'
    );
    is( _value( $ctx, $USER_NAMED_SQL, 'racer' ),
        $rival_id, 'registration unique race does not insert another user' );
    is( _value( $ctx, $USER_CREDENTIALS_SQL, $attempted ),
        0, 'registration unique race does not insert another credential' );
    is( _value( $ctx, $USER_EVENTS_SQL, $attempted ),
        0, 'and records no event for the account it refused' );

    return;
}

# The id the account was given already belongs to another member: the store
# mints a new one rather than answer with that member's account.
sub _registration_id_collision {
    my ($ctx) = @_;

    my $taken  = _member( $ctx, 'firstcomer' );
    my $result = _identity($ctx)
      ->create_registration( _registration_input( $ctx, $taken, 'nextcomer' ) );
    ok( $result->{ok}, 'unique user id collision remints and persists' );
    my $id = _value( $ctx, $USER_NAMED_SQL, 'nextcomer' );
    ok( GPForum::Infrastructure::Id->is_uuid($id) && $id ne $taken,
        'unique user id collision remints the id' );
    is( _column( $result->{user}, 'id' ),
        $id, 'unique user id collision does not return another user' );
    is( _value( $ctx, $USER_CREDENTIALS_SQL, $id ),
        1, 'and gives the reminted account its credential' );
    is( _column( $result->{user}, 'username' ),
        'nextcomer', 'unique user id collision keeps the minted username' );
    is( _row( $ctx, $USER_ROW_SQL, $taken )->{username},
        'firstcomer', 'and leaves the other member alone' );

    return;
}

# The rival commits this very account, under the id the store is inserting
# and with no password yet: the store finds its own account and adds the
# missing credential instead of minting a second account.
sub _registration_id_race {
    my ($ctx) = @_;

    my $id     = $ctx->{ids}->uuid;
    my $result = _before(
        $ctx,
        'user insert',
        sub {
            my ($rival) = @_;
            _rival_user( $rival, $id, 'returning' );
            return;
        },
        sub {
            return _identity($ctx)
              ->create_registration(
                _registration_input( $ctx, $id, 'returning' ) );
        }
    );
    ok( $result->{ok}, 'leftover user id race reuses and persists' );
    is( _value( $ctx, $USER_NAMED_SQL, 'returning' ),
        $id, 'leftover user id race keeps this account' );
    is( _value( $ctx, $USER_EMAIL_SQL, 'returning@example.test' ),
        1, 'leftover user id race does not insert a second user' );
    is( _value( $ctx, $USER_CREDENTIALS_SQL, $id ),
        1, 'leftover user id race inserts the missing credential' );

    return;
}

sub _login {
    my ($ctx) = @_;

    my $user = _member( $ctx, 'loginner' );
    my ( $login, $transactions ) = _transactions(
        $ctx,
        sub {
            return _identity($ctx)->authenticate_login(
                {
                    identifier      => 'LOGINNER@example.test',
                    password        => $PASSWORD,
                    request_address => $ADDRESS,
                    user_agent      => $AGENT,
                }
            );
        }
    );
    ok( $login->{ok}, 'valid login is accepted' );
    is( $login->{user_id}, $user, 'login returns authenticated user id' );
    my $session = _row( $ctx, $SESSION_ROW_SQL, $login->{session_id} );
    is( $session->{user_id}, $user, 'login persists a server-side session' );
    is(
        $session->{session_hash},
        sha256_hex( $login->{session_token} ),
        'under the hash of the token the login hands back'
    );
    is( $session->{ip_hash}, sha256_hex($ADDRESS),
        'login stores hashed request address' );
    is( _utc( $ctx, $session->{expires_at} ),
        $SESSION_END, 'and expires thirty days on' );
    is( $transactions, 1, 'login session creation uses one transaction' );

    my $failed =
      _identity($ctx)
      ->authenticate_login(
        { identifier => 'loginner', password => 'wrong password' } );
    ok( !$failed->{ok}, 'wrong password is rejected' );
    is( $failed->{error}, 'invalid_credentials',
        'login failure remains non-enumerative' );

    return;
}

# A login for an account that cannot sign in verifies a password all the
# same, against the decoy: its speed must not say which accounts exist.
sub _authentication {
    my ($ctx) = @_;

    my $member = _member( $ctx, 'regular' );
    _member( $ctx, 'gone',    { status     => 'deleted' } );
    _member( $ctx, 'keyless', { credential => 0 } );
    my $pending  = _member( $ctx, 'unconfirmed', { status => 'pending' } );
    my $store    = _auth_store($ctx);
    my $decoy    = $ctx->{password}->decoy_hash;
    my $verified = $ctx->{password}->verified;
    my $login    = sub {
        my ( $identifier, $password ) = @_;
        return $store->authenticate_login(
            { identifier => $identifier, password => $password // $PASSWORD } );
    };

    # A login's answer and the hashes it verified against. The last hash
    # verified says nothing on its own: a login that verified none leaves
    # the previous login's there.
    my $spent = sub {
        my $before = scalar @{$verified};
        my $answer = $login->(@_);
        return ( $answer, [ @{$verified}[ $before .. $#{$verified} ] ] );
    };

    my $by_email = $login->('REGULAR@example.test');
    ok( $by_email->{ok}, 'authenticate_login succeeds for a known email' );
    is( $by_email->{user_id},
        $member, 'authenticate_login returns the authenticated user id' );
    is( _row( $ctx, $SESSION_ROW_SQL, $by_email->{session_id} )->{user_id},
        $member, 'authenticate_login opens a server session' );
    ok( $login->('regular')->{ok},
        'authenticate_login succeeds for a known username' );

    my ( $wrong, $wrong_work ) = $spent->( 'regular', 'wrong password value' );
    is( $wrong->{error},
        'invalid_credentials', 'authenticate_login hides a wrong password' );
    is_deeply(
        $wrong_work,
        [ $ctx->{secret} ],
        'after one verification, against the member password'
    );

    my ( $unknown, $unknown_work ) = $spent->('missing@example.test');
    ok( !$unknown->{ok}, 'authenticate_login rejects an unknown identifier' );
    is( $unknown->{error}, 'invalid_credentials',
        'authenticate_login hides unknown identifiers' );
    is_deeply( $unknown_work, [$decoy],
        'and verifies the password against a decoy all the same' );
    my ( $deleted, $deleted_work ) = $spent->('gone');
    is( $deleted->{error},
        'invalid_credentials', 'authenticate_login hides deleted users' );
    is_deeply( $deleted_work, [$decoy],
        'a deleted account costs a verification too' );
    my ( $keyless, $keyless_work ) = $spent->('keyless');
    is( $keyless->{error}, 'invalid_credentials',
        'authenticate_login hides an account with no password' );
    is_deeply( $keyless_work, [$decoy], 'which costs a verification too' );

    my $refused = $login->('unconfirmed');
    is( $refused->{error}, 'unverified',
        'authenticate_login rejects a pending account' );
    ok( !$refused->{ok}, 'authenticate_login does not open a pending session' );

    # Unverified is said only to the holder of the password: told to anyone,
    # it would say which addresses have an account waiting for confirmation.
    is(
        $login->( 'unconfirmed', 'wrong password value' )->{error},
        'invalid_credentials',
        'a pending account with the wrong password is told nothing more'
    );
    is( _value( $ctx, $USER_SESSIONS_SQL, $pending ),
        0, 'and stores none for it' );
    is( _value( $ctx, $USER_SESSIONS_SQL, $member ),
        2,
        'authenticate_login opens a session only after a matching password' );

    return;
}

sub _logout {
    my ($ctx) = @_;

    my $user     = _member( $ctx, 'leaver' );
    my $session  = _session( $ctx, $user );
    my $revoke   = sub { return _identity($ctx)->revoke_session(@_); };
    my $revoked  = $revoke->( { session_id => $session, user_id => $user } );
    my $stamp_of = sub {
        return _utc( $ctx,
            _row( $ctx, $SESSION_ROW_SQL, $session )->{revoked_at} );
    };
    ok( $revoked->{ok}, 'logout revokes server-side session' );
    is( $stamp_of->(), $NOW, 'revoked session records revocation timestamp' );

    # An hour on, so a second logout that restamped the row would show.
    _at( $ctx, $LATER );
    my $version = _version( $ctx, session => $session );
    my $again   = $revoke->( { session_id => $session, user_id => $user } );
    ok( $again->{ok},      'second logout of the same session succeeds' );
    ok( $again->{skipped}, 'second logout of the same session is skipped' );
    is( $stamp_of->(), $NOW,
        'second logout keeps the original revocation timestamp' );
    is( _version( $ctx, session => $session ),
        $version, 'and does not write the row again' );
    _at( $ctx, $NOW );

    my $live    = _session( $ctx, $user );
    my $meddled = $revoke->(
        { session_id => $live, user_id => _member( $ctx, 'meddler' ) } );
    {
        local $TODO = $SESSION_TODO;
        is( $meddled->{error}, 'not_found',
            q{a member cannot revoke another member's session} );
        is( _row( $ctx, $SESSION_ROW_SQL, $live )->{revoked_at},
            undef, 'which stays live' );
    }

    return;
}

sub _session_validation {
    my ($ctx) = @_;

    my $user    = _member( $ctx, 'browser' );
    my %token   = map { $_ => "$_-session-token" } qw(valid expired revoked);
    my $valid   = _session( $ctx, $user, { token => $token{valid} } );
    my $expired = _session( $ctx, $user,
        { expires_at => $SEEN, token => $token{expired} } );
    my $revoked = _session( $ctx, $user,
        { revoked_at => $REVOKED, token => $token{revoked} } );
    my $identity_store = _identity($ctx);
    my $validate       = sub {
        my ( $session_id, $token, $user_id ) = @_;
        return $identity_store->validate_session(
            {
                session_id    => $session_id,
                session_token => $token,
                user_id       => $user_id // $user,
            }
        );
    };

    ok(
        $validate->( $valid, $token{valid} )->{ok},
        'server-side session validation accepts live row'
    );
    is( _utc( $ctx, _row( $ctx, $SESSION_ROW_SQL, $valid )->{last_seen_at} ),
        $NOW, 'live session updates last_seen_at' );

    my $expired_result = $validate->( $expired, $token{expired} );
    ok( !$expired_result->{ok}, 'expired server-side session is rejected' );
    is( $expired_result->{error},
        'expired', 'expired session error is explicit' );
    is( _utc( $ctx, _row( $ctx, $SESSION_ROW_SQL, $expired )->{revoked_at} ),
        $NOW, 'expired session is invalidated server-side' );

    my $revoked_result = $validate->( $revoked, $token{revoked} );
    ok( !$revoked_result->{ok}, 'revoked server-side session is rejected' );
    is( $revoked_result->{error},
        'revoked', 'revoked session error is explicit' );

    # sessions.session_hash used to hold the digest of a token the
    # application generated, hashed and then dropped on the floor: nothing
    # ever presented it and nothing ever compared it, so the column
    # authenticated nothing while its POD said raw tokens went to cookies.
    # The signed cookie now carries the token and validation compares it, so
    # a cookie alone is no longer sufficient. See docs/QUALITY_PROGRAM.md 2.1.
    my $wrong_token =
      $validate->( $valid, 'a token this session was never issued' );
    ok( !$wrong_token->{ok},
        'a session token that does not match is rejected' );
    is( $wrong_token->{error}, 'invalid_token',
        'the mismatch is reported as an invalid token' );
    ok( !$validate->($valid)->{ok},
        'a request that presents no token is rejected' );
    my $borrowed =
      $validate->( $valid, $token{valid}, _member( $ctx, 'borrower' ) );
    {
        local $TODO = $SESSION_TODO;
        is( $borrowed->{error}, 'not_found',
            q{a session presented under another member's id is not found} );
    }

    return;
}

sub _locale_preference {
    my ($ctx) = @_;

    my $user           = _member( $ctx, 'linguist' );
    my $identity_store = _identity($ctx);
    my $update         = sub {
        my ($locale) = @_;
        return $identity_store->update_preferred_locale(
            { preferred_locale => $locale, user_id => $user } );
    };

    my $locale =
      $identity_store->preferred_locale_for_user( { user_id => $user } );
    ok( $locale->{ok}, 'preferred_locale_for_user succeeds for a known user' );
    is( $locale->{preferred_locale},
        'en', 'preferred_locale_for_user returns the stored locale' );

    my $updated = $update->('it');
    ok( $updated->{ok}, 'preferred locale update succeeds' );
    is( $updated->{preferred_locale},
        'it', 'update_preferred_locale returns the new locale' );
    my $row = _row( $ctx, $USER_ROW_SQL, $user );
    is( $row->{preferred_locale},
        'it', 'preferred locale is persisted on the user row' );
    is( _utc( $ctx, $row->{updated_at} ),
        $NOW, 'preferred locale update refreshes user updated_at' );

    _at( $ctx, $LATER );
    my $version = _version( $ctx, user => $user );
    ok( $update->('it')->{skipped},
        'update_preferred_locale skips an unchanged locale' );
    $row = _row( $ctx, $USER_ROW_SQL, $user );
    is( $row->{preferred_locale}, 'it', 'unchanged locale stays persisted' );
    is( _utc( $ctx, $row->{updated_at} ),
        $NOW, 'unchanged locale does not restamp updated_at' );
    is( _version( $ctx, user => $user ),
        $version, 'unchanged locale does not write the row' );
    _at( $ctx, $NOW );

    is( $update->(q{})->{error},
        'locale_required', 'update_preferred_locale rejects an empty locale' );
    is(
        $identity_store->update_preferred_locale(
            { preferred_locale => 'it', user_id => $ctx->{ids}->uuid }
        )->{error},
        'not_found',
        'update_preferred_locale maps a missing user to not_found'
    );

    return;
}

sub _theme_preference {
    my ($ctx) = @_;

    my $user           = _member( $ctx, 'decorator' );
    my $identity_store = _identity($ctx);
    my $update         = sub {
        my ($theme) = @_;
        return $identity_store->update_preferred_theme(
            { preferred_theme => $theme, user_id => $user } );
    };

    my $theme = $update->('high_contrast');
    ok( $theme->{ok}, 'preferred theme update succeeds' );
    is( $theme->{preferred_theme},
        'high_contrast', 'update_preferred_theme returns the new theme' );
    my $row = _row( $ctx, $USER_ROW_SQL, $user );
    is( $row->{preferred_theme},
        'high_contrast', 'preferred theme is persisted on the user row' );
    is( _utc( $ctx, $row->{updated_at} ),
        $NOW, 'preferred theme update refreshes user updated_at' );
    is(
        $identity_store->preferred_theme_for_user( { user_id => $user } )
          ->{preferred_theme},
        'high_contrast',
        'preferred theme can be read back through identity store'
    );

    _at( $ctx, $LATEST );
    my $version = _version( $ctx, user => $user );
    ok( $update->('high_contrast')->{skipped},
        'update_preferred_theme skips an unchanged theme' );
    $row = _row( $ctx, $USER_ROW_SQL, $user );
    is( $row->{preferred_theme},
        'high_contrast', 'unchanged theme stays persisted' );
    is( _utc( $ctx, $row->{updated_at} ),
        $NOW, 'unchanged theme does not restamp updated_at' );
    is( _version( $ctx, user => $user ),
        $version, 'unchanged theme does not write the row' );
    _at( $ctx, $NOW );

    is( $update->(q{})->{error},
        'theme_required', 'update_preferred_theme rejects an empty theme' );

    return;
}

# 9.3: a zone is an IANA name, or empty for the forum's default (NULL).
sub _timezone_preference {
    my ($ctx) = @_;

    my $user           = _member( $ctx, 'traveller' );
    my $identity_store = _identity($ctx);
    my $update         = sub {
        my ($zone) = @_;
        return $identity_store->update_preferred_timezone(
            { preferred_timezone => $zone, user_id => $user } );
    };
    my $stored = sub {
        return _row( $ctx, $USER_ROW_SQL, $user )->{preferred_timezone};
    };

    ok( $update->('Europe/Rome')->{ok},
        'update_preferred_timezone stores a known zone' );
    is( $stored->(), 'Europe/Rome', 'on the user row' );
    ok( $update->('Europe/Rome')->{skipped}, 'and skips an unchanged one' );
    is( $update->('Mars/Olympus_Mons')->{error},
        'timezone_invalid',
        'refuses a name the time zone database does not know' );
    is( $stored->(), 'Europe/Rome', 'leaving the stored zone alone' );
    ok( $update->(q{})->{ok}, 'an empty zone is the forum default' );
    is( $stored->(), undef,
        'stored as NULL, so the member follows the default' );

    return;
}

sub _password_reset {
    my ($ctx) = @_;

    my $user       = _member( $ctx, 'forgetful' );
    my $credential = _row( $ctx, $ACTIVE_CREDENTIAL_SQL, $user )->{id};
    my $session    = _session( $ctx, $user );
    my ( $request, $transactions ) = _transactions(
        $ctx,
        sub {
            return _identity($ctx)->request_password_reset(
                {
                    identifier      => 'FORGETFUL@example.test',
                    request_address => $ADDRESS,
                }
            );
        }
    );
    ok( $request->{ok}, 'password reset request is accepted' );
    is( $transactions, 1,
        'password reset request runs inside one transaction' );
    my $raw   = $request->{token}{raw_token};
    my $token = _row( $ctx, $TOKEN_ROW_SQL, $request->{token}{token_id} );
    is( $token->{user_id}, $user, 'the reset token belongs to the member' );
    is( $token->{token_type}, 'password_reset',
        'request_password_reset asks for a password-reset token' );
    is( $token->{token_hash}, sha256_hex($raw), 'only token hash is stored' );
    is( _utc( $ctx, $token->{expires_at} ),
        $LATER, 'reset token expires after one hour' );
    is(
        _audit( $ctx, $user, 'identity.password_reset.requested' )
          ->{metadata}{outcome},
        'issued',
        'reset request is audited'
    );
    _assert_mail(
        $ctx, $user,
        {
            kind     => 'password_reset',
            to       => 'forgetful@example.test',
            token    => $raw,
            token_id => $token->{token_id},
        }
    );

    _reset_consumed(
        $ctx,
        {
            credential => $credential,
            raw        => $raw,
            session    => $session,
            token      => $token->{token_id},
            user       => $user,
        }
    );
    _reset_same_secret( $ctx, $user, $credential );

    my $reused = _identity($ctx)
      ->reset_password( { password => $OTHER_PASSWORD, token => $raw } );
    ok( !$reused->{ok}, 'used reset token is rejected' );
    is( $reused->{error}, 'token_used', 'used token error is explicit' );
    is( _value( $ctx, $USER_CREDENTIALS_SQL, $user ),
        2, 'used reset token does not create another credential' );
    is(
        _identity($ctx)
          ->reset_password( { password => $NEW_PASSWORD, token => 'bad' } )
          ->{error},
        'invalid_token',
        'reset_password rejects an invalid token'
    );

    return;
}

# The reset takes the token row's lock before it reads the row: a rival that
# asks for the same row in that window is refused at once.
sub _reset_consumed {
    my ( $ctx, $case ) = @_;

    my $lock_state = q{};
    my ( $reset, $transactions ) = _transactions(
        $ctx,
        sub {
            return _before(
                $ctx,
                'token read',
                sub {
                    my ($rival) = @_;
                    $lock_state = _lock_state( $rival, $case->{token} );
                    return;
                },
                sub {
                    return _identity($ctx)
                      ->reset_password(
                        { password => $NEW_PASSWORD, token => $case->{raw} } );
                }
            );
        }
    );
    ok( $reset->{ok}, 'password reset succeeds with valid token' );
    is( $transactions, 1, 'password reset runs inside one transaction' );
    is( $lock_state, $LOCK_NOT_AVAILABLE,
        'reset locks token row before consuming it' );
    is( _utc( $ctx, _row( $ctx, $TOKEN_ROW_SQL, $case->{token} )->{used_at} ),
        $NOW, 'reset marks token used' );
    is(
        _utc(
            $ctx,
            _row( $ctx, $CREDENTIAL_ROW_SQL, $case->{credential} )->{revoked_at}
        ),
        $NOW,
        'reset revokes old password credential'
    );
    my $active = _row( $ctx, $ACTIVE_CREDENTIAL_SQL, $case->{user} );
    ok(
        $ctx->{password}
          ->verify_password( $NEW_PASSWORD, $active->{secret_hash} ),
        'reset creates replacement password credential'
    );
    is(
        _row( $ctx, $USER_ROW_SQL, $case->{user} )->{password_hash},
        $active->{secret_hash},
        'reset_password persists the password hash'
    );
    is(
        _utc(
            $ctx, _row( $ctx, $SESSION_ROW_SQL, $case->{session} )->{revoked_at}
        ),
        $NOW,
        'reset revokes existing sessions'
    );
    is( _audits( $ctx, $case->{user}, 'identity.password_reset.completed' ),
        1, 'reset completion is audited' );

    return;
}

# A reset to the password the member already has still spends the token and
# signs every device out, but leaves the credential and the user row alone.
sub _reset_same_secret {
    my ( $ctx, $user, $credential ) = @_;

    _at( $ctx, $HALF_PAST );
    my $live   = _session( $ctx, $user );
    my $repeat = _identity($ctx)->request_password_reset(
        {
            identifier      => 'forgetful@example.test',
            request_address => $ADDRESS,
        }
    );
    ok( $repeat->{ok}, 'same-secret reset can issue a new token' );
    my $user_version = _version( $ctx, user => $user );
    my $user_row     = _row( $ctx, $USER_ROW_SQL, $user );
    my $completed = _audits( $ctx, $user, 'identity.password_reset.completed' );
    my $same =
      _identity($ctx)
      ->reset_password(
        { password => $NEW_PASSWORD, token => $repeat->{token}{raw_token} } );
    ok( $same->{ok},      'same-secret reset succeeds' );
    ok( $same->{skipped}, 'same-secret reset skips credential rotation' );
    is( _value( $ctx, $USER_CREDENTIALS_SQL, $user ),
        2, 'same-secret reset does not create another credential' );
    is(
        _utc(
            $ctx, _row( $ctx, $CREDENTIAL_ROW_SQL, $credential )->{revoked_at}
        ),
        $NOW,
        'same-secret reset keeps the original credential revocation'
    );
    is(
        _row( $ctx, $USER_ROW_SQL, $user )->{password_hash},
        $user_row->{password_hash},
        'unchanged reset secret keeps the password hash'
    );
    is( _version( $ctx, user => $user ),
        $user_version, 'unchanged reset secret does not restamp updated_at' );
    is(
        _utc( $ctx, _row( $ctx, $SESSION_ROW_SQL, $live )->{revoked_at} ),
        $HALF_PAST,
        'same-secret reset still revokes sessions, at the current time'
    );
    is(
        _audits( $ctx, $user, 'identity.password_reset.completed' ),
        $completed + 1,
        'unchanged reset secret still writes completion audit'
    );
    _at( $ctx, $NOW );

    return;
}

# Unknown and deleted accounts get the same answer as a known one, with no
# token and no mail behind it.
sub _password_reset_unknown {
    my ($ctx) = @_;

    my $deleted_user = _member( $ctx, 'departed', { status => 'deleted' } );
    my $identifier   = 'nobody@example.test';
    my $mails        = _value( $ctx, $ALL_MAILS_SQL );
    my $missing =
      _identity($ctx)
      ->request_password_reset(
        { identifier => $identifier, request_address => $ADDRESS } );
    ok( $missing->{ok},
        'request_password_reset succeeds for an unknown identifier' );
    is( $missing->{token}, undef,
        'request_password_reset hides unknown identifiers' );
    my $audit =
      _row( $ctx, $ANONYMOUS_AUDIT_SQL, 'identity.password_reset.requested',
        sha256_hex($identifier) );
    is( decode_json( $audit->{metadata} )->{outcome},
        'not_found', 'request_password_reset audits unknown identifiers' );

    my $deleted =
      _identity($ctx)
      ->request_password_reset(
        { identifier => 'departed', request_address => $ADDRESS } );
    is( $deleted->{token}, undef,
        'request_password_reset hides deleted identifiers' );
    is( _value( $ctx, $USER_TOKENS_SQL, $deleted_user ),
        0, 'and issues it no token' );
    is( _value( $ctx, $ALL_MAILS_SQL ),
        $mails, 'unknown identifier does not queue another mail job' );

    return;
}

# A second request while the first token is unused rotates that row: one
# open token per member and purpose, under a new hash, mailed again.
sub _password_reset_rotation {
    my ($ctx) = @_;

    my $user    = _member( $ctx, 'twice' );
    my $request = sub {
        return _identity($ctx)->request_password_reset(
            {
                identifier      => 'twice@example.test',
                request_address => $ADDRESS,
            }
        );
    };
    my $first = $request->();
    ok( $first->{ok}, 'first password reset request is accepted' );
    my $rotated = $request->();
    ok( $rotated->{ok}, 'second password reset request is accepted' );
    ok( $rotated->{token}{rotated},
        'second password reset rotates the unused token' );
    isnt(
        $rotated->{token}{raw_token},
        $first->{token}{raw_token},
        'rotated reset token returns the new raw token'
    );
    is( _value( $ctx, $USER_TOKENS_SQL, $user ),
        1, 'second password reset does not insert another token row' );
    is(
        _row( $ctx, $USER_TOKEN_SQL, $user )->{token_hash},
        sha256_hex( $rotated->{token}{raw_token} ),
        'rotated reset token replaces the previous hash'
    );
    my $mails = _mails( $ctx, $user );
    is( scalar @{$mails}, 2, 'each request queues its mail' );
    is(
        $mails->[-1]{outbox}{mail}{token},
        $rotated->{token}{raw_token},
        'the latest with the rotated token'
    );
    is(
        _identity($ctx)->reset_password(
            { password => $NEW_PASSWORD, token => $first->{token}{raw_token} }
        )->{error},
        'invalid_token',
        'the replaced token no longer resets the password'
    );

    return;
}

sub _password_change {
    my ($ctx) = @_;

    my $user       = _member( $ctx, 'cautious' );
    my $credential = _row( $ctx, $ACTIVE_CREDENTIAL_SQL, $user )->{id};
    my $current    = _session( $ctx, $user );
    my $other      = _session( $ctx, $user );
    my $bystander  = _session( $ctx, _member( $ctx, 'bystander' ) );
    my $change     = sub {
        my ($input) = @_;
        return _identity($ctx)
          ->change_password( { user_id => $user, %{$input} } );
    };

    my $wrong = $change->(
        { current_password => 'wrong password', new_password => $NEW_PASSWORD }
    );
    ok( !$wrong->{ok}, 'wrong current password is rejected' );
    is( $wrong->{error},
        'invalid_current_password', 'current password error is explicit' );
    is(
        $change->(
            {
                current_password => $PASSWORD,
                new_password     => $NEW_PASSWORD,
                user_id          => $ctx->{ids}->uuid,
            }
        )->{error},
        'not_found',
        'change_password maps a missing user to not_found'
    );

    # A password reset already revoked every session. A change did not, so a
    # user who changed their password because they suspected a compromise
    # left every other device signed in. See docs/QUALITY_PROGRAM.md 2.4.
    my $changed = $change->(
        {
            current_password => $PASSWORD,
            keep_session_id  => $current,
            new_password     => $NEWER_PASSWORD,
        }
    );
    ok( $changed->{ok}, 'password change succeeds' );
    is(
        _utc(
            $ctx, _row( $ctx, $CREDENTIAL_ROW_SQL, $credential )->{revoked_at}
        ),
        $NOW,
        'old credential is revoked'
    );
    my $active = _row( $ctx, $ACTIVE_CREDENTIAL_SQL, $user );
    ok(
        $ctx->{password}
          ->verify_password( $NEWER_PASSWORD, $active->{secret_hash} ),
        'new credential is created'
    );
    is(
        _row( $ctx, $USER_ROW_SQL, $user )->{password_hash},
        $active->{secret_hash},
        'and the user row holds its hash'
    );
    {
        # Its revocation, when the next change comes, is stamped by the
        # store's clock; a clock behind the database's then breaks the
        # credentials_revoked_after_created_check.
        local $TODO = $CREDENTIAL_TODO;
        is( _utc( $ctx, $active->{created_at} ),
            $NOW, 'the new credential is stamped by the store clock' );
    }
    _assert_change_sessions( $ctx, $changed,
        { bystander => $bystander, current => $current, other => $other } );
    is( _audits( $ctx, $user, 'identity.password.changed' ),
        1, 'password change is audited' );

    my $credentials = _value( $ctx, $USER_CREDENTIALS_SQL, $user );
    my $same        = $change->(
        {
            current_password => $NEWER_PASSWORD,
            new_password     => $NEWER_PASSWORD,
        }
    );
    ok( $same->{ok}, 'change_password succeeds when the secret is unchanged' );
    ok( $same->{skipped}, 'change_password skips an unchanged secret' );
    is( _value( $ctx, $USER_CREDENTIALS_SQL, $user ),
        $credentials, 'unchanged secret does not rotate the credential' );
    is( _audits( $ctx, $user, 'identity.password.changed' ),
        1, 'unchanged secret does not write another audit' );

    return;
}

sub _assert_change_sessions {
    my ( $ctx, $changed, $session ) = @_;

    my $revoked_at = sub {
        my ($id) = @_;
        return _row( $ctx, $SESSION_ROW_SQL, $id )->{revoked_at};
    };
    is( $changed->{revoked_sessions},
        1, 'change_password revokes the user sessions' );
    is( _utc( $ctx, $revoked_at->( $session->{other} ) ),
        $NOW, 'change_password revokes the sessions of that user' );
    is( $revoked_at->( $session->{current} ),
        undef, 'change_password keeps the session the user is typing in' );
    is( $revoked_at->( $session->{bystander} ),
        undef, 'and leaves other members signed in' );

    return;
}

sub _email_change {
    my ($ctx) = @_;

    my $user = _member( $ctx, 'mover', { verified_at => $EARLY } );
    _member( $ctx, 'neighbour' );
    my $request = sub {
        my ($email) = @_;
        return _identity($ctx)->request_email_change(
            {
                email           => $email,
                request_address => $ADDRESS,
                user_id         => $user,
            }
        );
    };

    my $duplicate = $request->('neighbour@example.test');
    ok( !$duplicate->{ok}, 'duplicate email change is rejected' );
    is( $duplicate->{error},
        'email_already_registered', 'duplicate email error is explicit' );

    my $requested = $request->('MOVED@example.test');
    ok( $requested->{ok}, 'email change request succeeds' );
    my $raw   = $requested->{token}{raw_token};
    my $token = _row( $ctx, $TOKEN_ROW_SQL, $requested->{token}{token_id} );
    is( $token->{email_normalized},
        'moved@example.test', 'pending email is normalized in token row' );
    is( $token->{token_type}, 'email_change',
        'request_email_change asks for an email-change token' );
    is( $token->{token_hash}, sha256_hex($raw),
        'email confirmation stores token hash' );
    is( _audits( $ctx, $user, 'identity.email_change.requested' ),
        1, 'email change request is audited' );
    is( _mails( $ctx, $user )->[-1]{outbox}{mail}{to},
        'moved@example.test',
        'email change mail is addressed to the pending address' );

    my $confirmed = _identity($ctx)->confirm_email_change( { token => $raw } );
    ok( $confirmed->{ok}, 'email confirmation succeeds' );
    my $row = _row( $ctx, $USER_ROW_SQL, $user );
    is( $row->{email_normalized},
        'moved@example.test', 'confirmed email is persisted' );
    is( _utc( $ctx, $row->{email_verified_at} ),
        $NOW, 'confirmed email is verified' );
    is(
        _utc(
            $ctx, _row( $ctx, $TOKEN_ROW_SQL, $token->{token_id} )->{used_at}
        ),
        $NOW,
        'email token is consumed'
    );
    is( _audits( $ctx, $user, 'identity.email_change.confirmed' ),
        1, 'email confirmation is audited' );

    my $reused = _identity($ctx)->confirm_email_change( { token => $raw } );
    ok( !$reused->{ok}, 'used email token is rejected' );
    is( $reused->{error}, 'token_used', 'used email token error is explicit' );

    _email_already_confirmed( $ctx, $user, $request );

    return;
}

# Confirming, or asking again for, the address the member already has
# verified changes nothing and records nothing.
sub _email_already_confirmed {
    my ( $ctx, $user, $request ) = @_;

    _at( $ctx, $LATER );
    my $version = _version( $ctx, user => $user );
    my $raw     = _token(
        $ctx,
        {
            email   => 'moved@example.test',
            type    => 'email_change',
            user_id => $user,
        }
    );
    my $same = _identity($ctx)->confirm_email_change( { token => $raw } );
    ok( $same->{ok},
        'confirm_email_change succeeds for the already-confirmed address' );
    ok( $same->{skipped}, 'already-confirmed email change is skipped' );
    my $row = _row( $ctx, $USER_ROW_SQL, $user );
    is( $row->{email_normalized},
        'moved@example.test', 'already-confirmed email keeps the address' );
    is( _utc( $ctx, $row->{email_verified_at} ),
        $NOW, 'already-confirmed email keeps the original timestamp' );
    is( _version( $ctx, user => $user ),
        $version, 'already-confirmed email does not restamp updated_at' );
    is( _audits( $ctx, $user, 'identity.email_change.confirmed' ),
        1, 'already-confirmed email does not write another audit' );

    my $tokens       = _value( $ctx, $USER_TOKENS_SQL, $user );
    my $mails        = scalar @{ _mails( $ctx, $user ) };
    my $same_request = $request->('MOVED@example.test');
    ok( $same_request->{ok},
        'request_email_change succeeds for the current verified address' );
    ok( $same_request->{skipped},
        'request_email_change skips the current verified address' );
    is( $same_request->{token},
        undef, 'request_email_change does not issue another token' );
    is( _value( $ctx, $USER_TOKENS_SQL, $user ),
        $tokens, 'current verified address does not create another token' );
    is( scalar @{ _mails( $ctx, $user ) },
        $mails, 'current verified address does not queue another mail job' );
    is( _audits( $ctx, $user, 'identity.email_change.requested' ),
        1, 'current verified address does not write another audit' );
    _at( $ctx, $NOW );

    return;
}

sub _email_change_refusals {
    my ($ctx) = @_;

    my $user = _member( $ctx, 'hesitant' );
    _member( $ctx, 'owner' );
    my $confirm = sub {
        my ($row) = @_;
        return _identity($ctx)->confirm_email_change(
            {
                token => _token(
                    $ctx, { type => 'email_change', user_id => $user, %{$row} }
                )
            }
        )->{error};
    };

    is( $confirm->( { email => undef } ),
        'invalid_token',
        'confirm_email_change rejects a token without an email' );
    is(
        $confirm->( { email => 'stray@example.test', user_id => undef } ),
        'invalid_token',
        'confirm_email_change rejects a token for a missing user'
    );
    is(
        $confirm->( { email => 'owner@example.test' } ),
        'email_already_registered',
        'confirm_email_change refuses an address another member took since'
    );
    is( _row( $ctx, $USER_ROW_SQL, $user )->{email_normalized},
        'hesitant@example.test', 'leaving the member address alone' );
    is( $confirm->( { email => 'late@example.test', expires_at => $SEEN } ),
        'token_expired', 'confirm_email_change rejects an expired token' );

    return;
}

# The address was free when the store looked, twice, and is taken by the
# time its UPDATE reaches PostgreSQL: the unique constraint refuses it, the
# savepoint keeps the transaction usable, and the member keeps the address
# they had.
sub _email_change_race {
    my ($ctx) = @_;

    my $user  = _member( $ctx, 'slowpoke' );
    my $racer = _member( $ctx, 'quickdraw' );
    my $raw   = _token(
        $ctx,
        {
            email   => 'contested@example.test',
            type    => 'email_change',
            user_id => $user,
        }
    );
    my $raced = _before(
        $ctx,
        'user update',
        sub {
            my ($rival) = @_;
            $rival->storage->dbh->do( $TAKE_EMAIL_SQL, undef,
                'contested@example.test', $racer );
            return;
        },
        sub {
            return _identity($ctx)->confirm_email_change( { token => $raw } );
        }
    );
    is( $raced->{error}, 'email_already_registered',
        'unique email-change race rejects a taken address' );
    ok( !$raced->{ok}, 'unique email-change race does not confirm' );
    is( _row( $ctx, $USER_ROW_SQL, $user )->{email_normalized},
        'slowpoke@example.test',
        'unique email-change race keeps the stored address' );
    is( _audits( $ctx, $user, 'identity.email_change.confirmed' ),
        0, 'unique email-change race does not write another audit' );
    ok( _row( $ctx, $USER_TOKEN_SQL, $user )->{used_at},
        'and the transaction outlives the conflict: the token is spent' );

    return;
}

sub _email_verification {
    my ($ctx) = @_;

    my $pending = _member( $ctx, 'newcomer', { status      => 'pending' } );
    my $settled = _member( $ctx, 'settled',  { verified_at => $EARLY } );
    my $request = sub {
        my ($identifier) = @_;
        return _identity($ctx)
          ->request_email_verification(
            { identifier => $identifier, request_address => $ADDRESS } );
    };

    my $verify = $request->('newcomer');
    ok( $verify->{ok},
        'request_email_verification succeeds for a pending user' );
    is(
        _row( $ctx, $TOKEN_ROW_SQL, $verify->{token}{token_id} )->{token_type},
        'email_verification',
        'request_email_verification asks for a verification token'
    );
    is( $verify->{email_normalized},
        'newcomer@example.test',
        'request_email_verification returns the pending email' );
    is( _mails( $ctx, $pending )->[-1]{outbox}{mail}{kind},
        'email_verification', 'and mails it' );
    is( $request->('settled')->{token},
        undef, 'request_email_verification hides an already active account' );

    my $verified = _identity($ctx)
      ->confirm_email_verification( { token => $verify->{token}{raw_token} } );
    ok( $verified->{ok},
        'confirm_email_verification succeeds for a valid token' );
    my $row = _row( $ctx, $USER_ROW_SQL, $pending );
    is( $row->{status}, 'active',
        'confirm_email_verification activates the pending user' );
    is( _utc( $ctx, $row->{email_verified_at} ),
        $NOW, 'confirm_email_verification marks the email verified' );

    _at( $ctx, $LATER );
    my $version = _version( $ctx, user => $settled );
    my $again   = _identity($ctx)->confirm_email_verification(
        {
            token => _token(
                $ctx, { type => 'email_verification', user_id => $settled }
            )
        }
    );
    ok( $again->{ok},
        'confirm_email_verification succeeds for an already-verified user' );
    ok( $again->{skipped}, 'already-verified email confirmation is skipped' );
    is(
        _utc(
            $ctx, _row( $ctx, $USER_ROW_SQL, $settled )->{email_verified_at}
        ),
        $EARLY,
        'already-verified email keeps the original timestamp'
    );
    is( _version( $ctx, user => $settled ),
        $version, 'already-verified email does not restamp updated_at' );
    is( _audits( $ctx, $settled, 'identity.email_verification.confirmed' ),
        0, 'already-verified email does not write another audit' );
    _at( $ctx, $NOW );

    return;
}

sub _credential_rows {
    my ($ctx) = @_;

    my $user       = _member( $ctx, 'keyholder', { credential => 0 } );
    my $store      = _credentials($ctx);
    my $credential = _in_transaction(
        $ctx,
        sub {
            return $store->create_password_credential(
                { secret_hash => 'argon2id-hash', user_id => $user } );
        }
    );
    my $id = _column( $credential, 'id' );
    ok(
        GPForum::Infrastructure::Id->is_uuid($id),
        'password credential id is generated'
    );
    is( _row( $ctx, $CREDENTIAL_ROW_SQL, $id )->{user_id},
        $user, 'and its row belongs to the member' );

    my $same = _in_transaction(
        $ctx,
        sub {
            return $store->create_password_credential(
                { secret_hash => 'argon2id-hash-other', user_id => $user } );
        }
    );
    ok( _skipped($same),
        'already-active password credential skip does not insert a second row'
    );
    is( _value( $ctx, $USER_CREDENTIALS_SQL, $user ),
        1, 'already-active password credential does not insert a second row' );

    return;
}

# The rival commits an active password for the same member between the
# store's look-up, which found none, and its insert: the partial unique
# index refuses a second active password and the store reuses the rival's.
sub _credential_race {
    my ($ctx) = @_;

    my $user   = _member( $ctx, 'contender', { credential => 0 } );
    my $stored = $ctx->{ids}->uuid;
    my $raced  = _before(
        $ctx,
        'credential insert',
        sub {
            my ($rival) = @_;
            $rival->storage->dbh->do(
                $CREDENTIAL_SQL,  undef, $stored, $user,
                'argon2id-rival', $EARLY
            );
            return;
        },
        sub {
            return _in_transaction(
                $ctx,
                sub {
                    return _credentials($ctx)->create_password_credential(
                        {
                            secret_hash => 'argon2id-hash-race',
                            user_id     => $user,
                        }
                    );
                }
            );
        }
    );
    ok( _skipped($raced), 'unique active password race reuses the credential' );
    is( _column( $raced, 'id' ), $stored, 'the one the rival stored' );
    is( _value( $ctx, $ACTIVE_CREDENTIALS_SQL, $user ),
        1, 'and the member keeps one active password' );

    return;
}

# The id the store mints is another member's credential: it mints a new one.
sub _credential_id_collision {
    my ($ctx) = @_;

    my $other   = _member( $ctx, 'incumbent' );
    my $taken   = _row( $ctx, $ACTIVE_CREDENTIAL_SQL, $other )->{id};
    my $user    = _member( $ctx, 'newkey', { credential => 0 } );
    my $created = _in_transaction(
        $ctx,
        sub {
            return _credentials( $ctx,
                id_service =>
                  GPForum::Test::ScriptedId->new( next_ids => [$taken] ) )
              ->create_password_credential(
                { secret_hash => 'argon2id-hash-new', user_id => $user } );
        }
    );
    my $id = _column( $created, 'id' );
    ok(
        GPForum::Infrastructure::Id->is_uuid($id) && $id ne $taken,
        'unique credential id collision remints the id'
    );
    is( _column( $created, 'user_id' ),
        $user, 'unique credential id collision does not return another user' );
    ok( !_skipped($created),
        'unique credential id collision does not skip another credential' );
    is( _value( $ctx, $USER_CREDENTIALS_SQL, $user ),
        1, 'unique credential id collision inserts one retried credential' );
    is( _row( $ctx, $CREDENTIAL_ROW_SQL, $taken )->{user_id},
        $other, 'and leaves the other credential alone' );

    return;
}

# The rival commits this very credential, under the id the store is about
# to use, between the store's look-up and its insert: the store reuses it.
sub _credential_id_race {
    my ($ctx) = @_;

    my $user  = _member( $ctx, 'retrier', { credential => 0 } );
    my $id    = $ctx->{ids}->uuid;
    my $raced = _before(
        $ctx,
        'credential insert',
        sub {
            my ($rival) = @_;
            $rival->storage->dbh->do( $CREDENTIAL_SQL, undef, $id, $user,
                'argon2id-leftover', $EARLY );
            return;
        },
        sub {
            return _in_transaction(
                $ctx,
                sub {
                    return _credentials( $ctx,
                        id_service =>
                          GPForum::Test::ScriptedId->new( next_ids => [$id] ) )
                      ->create_password_credential(
                        {
                            secret_hash => 'argon2id-hash-leftover',
                            user_id     => $user,
                        }
                      );
                }
            );
        }
    );
    ok( _skipped($raced),
        'leftover credential id race reuses this credential' );
    is( _column( $raced, 'id' ),
        $id, 'leftover credential id race keeps this credential' );
    is( _column( $raced, 'user_id' ),
        $user, 'leftover credential id race keeps this user' );
    is( _value( $ctx, $USER_CREDENTIALS_SQL, $user ),
        1, 'leftover credential id race does not insert a second credential' );

    return;
}

# The token the store mints hashes to a session another member holds: it
# mints another, and hands back that one.
sub _session_hash_collision {
    my ($ctx) = @_;

    my $other = _member( $ctx, 'holder' );
    my $taken =
      _session( $ctx, $other, { hash => _minted_hash( 'session_hash', 1 ) } );
    my $user    = _member( $ctx, 'arrival' );
    my $created = _sessions( $ctx, session_tokens => _minted('session_hash') )
      ->create_session( { id => $user }, _session_request() );
    my $id  = _column( $created->{session}, 'session_id' );
    my $row = _row( $ctx, $SESSION_ROW_SQL, $id );
    is(
        $row->{session_hash},
        _minted_hash( 'session_hash', 2 ),
        'unique session hash collision remints the hash'
    );
    is( $row->{user_id}, $user,
        'unique session hash collision does not return another user' );
    ok(
        GPForum::Infrastructure::Id->is_uuid($id) && $id ne $taken,
        'unique session hash collision keeps a new session id'
    );
    is( _value( $ctx, $USER_SESSIONS_SQL, $user ),
        1, 'unique session hash collision inserts one retried session' );
    is(
        $created->{session_token},
        _minted_token( 'session_hash', 2 ),
        'and hands back the reminted token, whose hash is the one stored'
    );

    return;
}

# The id the store mints is another member's session: it mints a new one.
sub _session_id_collision {
    my ($ctx) = @_;

    my $other   = _member( $ctx, 'squatter' );
    my $taken   = _session( $ctx, $other );
    my $user    = _member( $ctx, 'visitor' );
    my $created = _sessions(
        $ctx,
        id_service => GPForum::Test::ScriptedId->new( next_ids => [$taken] ),
        session_tokens => _minted('session_id'),
    )->create_session( { id => $user }, _session_request() );
    my $id  = _column( $created->{session}, 'session_id' );
    my $row = _row( $ctx, $SESSION_ROW_SQL, $id );
    ok( GPForum::Infrastructure::Id->is_uuid($id) && $id ne $taken,
        'unique session id collision remints the id' );
    is( $row->{user_id}, $user,
        'unique session id collision does not return another user' );
    is(
        $row->{session_hash},
        _minted_hash( 'session_id', 1 ),
        'unique session id collision keeps the minted hash'
    );
    is( _value( $ctx, $USER_SESSIONS_SQL, $user ),
        1, 'unique session id collision inserts one retried session' );
    is( _row( $ctx, $SESSION_ROW_SQL, $taken )->{user_id},
        $other, 'and leaves the other session alone' );

    return;
}

# A session stored before, under the id the store mints and the hash of the
# token it issues: the store reuses it rather than mint another.
sub _session_id_leftover {
    my ($ctx) = @_;

    my $user = _member( $ctx, 'returner' );
    my $id   = _session( $ctx, $user,
        { hash => _minted_hash( 'session_leftover', 1 ) } );
    my $created = _sessions(
        $ctx,
        id_service     => GPForum::Test::ScriptedId->new( next_ids => [$id] ),
        session_tokens => _minted('session_leftover'),
    )->create_session( { id => $user }, _session_request() );
    ok( $created->{skipped}, 'leftover session id race reuses this session' );
    is( _column( $created->{session}, 'session_id' ),
        $id, 'leftover session id race keeps this session' );
    is( _column( $created->{session}, 'user_id' ),
        $user, 'leftover session id race keeps this user' );
    is( _value( $ctx, $USER_SESSIONS_SQL, $user ),
        1, 'leftover session id race does not insert a second session' );

    return;
}

# The token the store mints hashes to another member's token: it mints
# another.
sub _token_hash_collision {
    my ($ctx) = @_;

    my $other = _member( $ctx, 'tokenholder' );
    _token_row(
        $ctx,
        {
            hash    => _minted_hash( 'token_hash', 1 ),
            used_at => $SEEN,
            user_id => $other,
        }
    );
    my $user = _member( $ctx, 'tokenseeker' );
    my $issued =
      _issue( $ctx, $user, { session_tokens => _minted('token_hash') } );
    is(
        $issued->{token_hash},
        _minted_hash( 'token_hash', 2 ),
        'unique token hash collision remints the hash'
    );
    is( _column( $issued->{row}, 'user_id' ),
        $user, 'unique token hash collision does not return another user' );
    ok( !$issued->{rotated},
        'unique token hash collision does not rotate another token' );
    is( _value( $ctx, $USER_TOKENS_SQL, $user ),
        1, 'unique token hash collision inserts one retried token' );
    is(
        _row( $ctx, $USER_TOKEN_SQL, $user )->{token_hash},
        _minted_hash( 'token_hash', 2 ),
        'and stores the hash of the token it hands back'
    );

    return;
}

# The id the store mints is another member's token: it mints a new one.
sub _token_id_collision {
    my ($ctx) = @_;

    my $other = _member( $ctx, 'tokenowner' );
    my $taken = _token_row(
        $ctx,
        {
            hash    => 'hash:another-token',
            used_at => $SEEN,
            user_id => $other,
        }
    );
    my $user   = _member( $ctx, 'tokenclaimer' );
    my $issued = _issue(
        $ctx, $user,
        {
            id_service =>
              GPForum::Test::ScriptedId->new( next_ids => [$taken] ),
            session_tokens => _minted('token_id'),
        }
    );
    ok(
        GPForum::Infrastructure::Id->is_uuid( $issued->{token_id} )
          && $issued->{token_id} ne $taken,
        'unique token id collision remints the id'
    );
    is( _column( $issued->{row}, 'user_id' ),
        $user, 'unique token id collision does not return another user' );
    is(
        $issued->{token_hash},
        _minted_hash( 'token_id', 1 ),
        'unique token id collision keeps the minted hash'
    );
    is( _value( $ctx, $USER_TOKENS_SQL, $user ),
        1, 'unique token id collision inserts one retried token' );
    is( _row( $ctx, $TOKEN_ROW_SQL, $taken )->{user_id},
        $other, 'and leaves the other token alone' );

    return;
}

# A token stored before, under the id the store mints and the hash of the
# token it issues: the store reuses it rather than mint another.
sub _token_id_leftover {
    my ($ctx) = @_;

    my $user = _member( $ctx, 'tokenreturner' );
    my $id   = _token_row( $ctx,
        { hash => _minted_hash( 'token_leftover', 1 ), user_id => $user } );
    my $issued = _issue(
        $ctx, $user,
        {
            id_service => GPForum::Test::ScriptedId->new( next_ids => [$id] ),
            session_tokens => _minted('token_leftover'),
        }
    );
    ok( $issued->{skipped}, 'leftover token id race reuses this token' );
    is( $issued->{token_id}, $id, 'leftover token id race keeps this token' );
    is( _column( $issued->{row}, 'user_id' ),
        $user, 'leftover token id race keeps this user' );
    is( _value( $ctx, $USER_TOKENS_SQL, $user ),
        1, 'leftover token id race does not insert a second token' );

    return;
}

sub _identity {
    my ( $ctx, %options ) = @_;

    return GPForum::Service::Identity::Store->new(
        clock      => $ctx->{clock},
        id_service => $ctx->{ids},
        password   => $ctx->{password},
        schema     => $ctx->{schema},
        %options,
    );
}

sub _auth_store {
    my ($ctx) = @_;

    return GPForum::Service::Identity::AuthStore->new(
        credential_store => _credentials($ctx),
        password         => $ctx->{password},
        schema           => $ctx->{schema},
        session_store    => _sessions($ctx),
    );
}

sub _credentials {
    my ( $ctx, %options ) = @_;

    return GPForum::Service::Identity::CredentialStore->new(
        clock      => $ctx->{clock},
        id_service => $ctx->{ids},
        schema     => $ctx->{schema},
        %options,
    );
}

sub _sessions {
    my ( $ctx, %options ) = @_;

    return GPForum::Service::Identity::SessionStore->new(
        clock      => $ctx->{clock},
        id_service => $ctx->{ids},
        schema     => $ctx->{schema},
        %options,
    );
}

# A password-reset token for $user from a TokenStore built with %{$options},
# issued inside a transaction as the account store issues it.
sub _issue {
    my ( $ctx, $user, $options ) = @_;

    my $store = GPForum::Service::Identity::TokenStore->new(
        clock      => $ctx->{clock},
        id_service => $ctx->{ids},
        schema     => $ctx->{schema},
        %{$options},
    );

    return _in_transaction(
        $ctx,
        sub {
            return $store->create_token(
                {
                    token_type  => 'password_reset',
                    ttl_seconds => $HOUR,
                    user_id     => $user,
                }
            );
        }
    );
}

sub _registration_input {
    my ( $ctx, $id, $name ) = @_;

    return {
        credential => {
            secret_hash => $ctx->{secret},
            type        => 'password',
        },
        user => {
            display_name     => ucfirst $name,
            email_normalized => "$name\@example.test",
            id               => $id,
            status           => 'pending',
            trust_level      => 0,
            username         => $name,
        },
    };
}

sub _session_request {
    return { request_address => $ADDRESS, user_agent => $AGENT };
}

# A member named $name, active, with $name@example.test and the context's
# password, unless %{$options} says otherwise.
sub _member {
    my ( $ctx, $name, $options ) = @_;

    my %option = ( credential => 1, status => 'active', %{ $options // {} } );
    my $id     = $ctx->{ids}->uuid;
    $ctx->{dbh}->do(
        $USER_SQL,      undef,
        $id,            $name,
        ucfirst $name,  "$name\@example.test",
        $ctx->{secret}, $option{status},
        $option{verified_at}
    );
    if ( $option{credential} ) {
        $ctx->{dbh}->do(
            $CREDENTIAL_SQL, undef,          $ctx->{ids}->uuid,
            $id,             $ctx->{secret}, $EARLY
        );
    }

    return $id;
}

# What a concurrent registration commits: a pending account, no password.
sub _rival_user {
    my ( $rival, $id, $name ) = @_;

    $rival->storage->dbh->do( $USER_SQL, undef, $id, $name, ucfirst $name,
        "$name\@example.test", 'argon2id-rival', 'pending', undef );

    return;
}

# A live session for $user, opened early in the day and good until
# tomorrow, under its own token unless %{$row} names one.
sub _session {
    my ( $ctx, $user, $row ) = @_;

    my %column = (
        expires_at => $TOMORROW,
        revoked_at => undef,
        token      => 'session-' . ++$ctx->{serial},
        %{ $row // {} },
    );
    my $id = $ctx->{ids}->uuid;
    $ctx->{dbh}->do( $SESSION_SQL, undef, $id, $user,
        $column{hash} // sha256_hex( $column{token} ),
        $EARLY, $EARLY, $column{expires_at}, $column{revoked_at} );

    return $id;
}

# An open token, issued early in the day and good until tomorrow; returns the
# raw token a mail would have carried.
sub _token {
    my ( $ctx, $row ) = @_;

    my $raw = 'identity-token-' . ++$ctx->{serial};
    _token_row( $ctx, { hash => sha256_hex($raw), %{$row} } );

    return $raw;
}

sub _token_row {
    my ( $ctx, $row ) = @_;

    my %column = (
        email      => undef,
        expires_at => $TOMORROW,
        type       => 'password_reset',
        used_at    => undef,
        %{$row},
    );
    my $id = $ctx->{ids}->uuid;
    $ctx->{dbh}
      ->do( $TOKEN_SQL, undef, $id, @column{qw(user_id type hash email)},
        $EARLY, @column{qw(expires_at used_at)} );

    return $id;
}

# Deterministic tokens for a collision case: token-<n> hashed as
# hash:token-<n>, numbered from the case's own series.
sub _minted {
    my ($series) = @_;

    return GPForum::Test::SessionToken->new( value => $SERIES{$series} );
}

sub _minted_token {
    my ( $series, $nth ) = @_;

    return 'token-' . ( $SERIES{$series} + $nth );
}

sub _minted_hash {
    my ( $series, $nth ) = @_;

    return 'hash:' . _minted_token( $series, $nth );
}

# The audit row of $action on $user, its metadata decoded.
sub _audit {
    my ( $ctx, $user, $action ) = @_;

    my $row = _row( $ctx, $AUDIT_ACTION_SQL, $user, $action );
    $row->{metadata} = decode_json( $row->{metadata} // '{}' );

    return $row;
}

sub _audits {
    my ( $ctx, $user, $action ) = @_;

    return _value( $ctx, $USER_AUDITS_SQL, $user, $action );
}

# The identity mails queued for $user, oldest first: each event's payload
# and its outbox message's, decoded.
sub _mails {
    my ( $ctx, $user ) = @_;

    my $rows =
      $ctx->{dbh}->selectall_arrayref( $MAILS_SQL, { Slice => {} }, $user );

    return [
        map {
            {
                event  => decode_json( $_->{event} ),
                outbox => decode_json( $_->{outbox} ),
            }
        } @{$rows}
    ];
}

# The mail event keeps the kind and the token id; only its outbox message,
# which the worker delivers and retention purges, carries the raw token.
sub _assert_mail {
    my ( $ctx, $user, $mail ) = @_;

    my $queued = _mails( $ctx, $user )->[-1];
    is_deeply(
        $queued->{event},
        { kind => $mail->{kind}, token_id => $mail->{token_id} },
        'mail event payload keeps kind and token id only'
    );
    is( $queued->{outbox}{mail}{token},
        $mail->{token},
        'mail outbox payload keeps the raw token until delivery' );
    is( $queued->{outbox}{mail}{to},
        $mail->{to}, 'reset mail uses the member address' );

    return;
}

# The SQLSTATE a rival gets asking, without waiting, for the token row's
# lock; empty when it got the lock.
sub _lock_state {
    my ( $rival, $token_id ) = @_;

    my $dbh   = $rival->storage->dbh;
    my $taken = eval {
        $dbh->selectrow_array( $LOCK_SQL, undef, $token_id );
        1;
    };

    return $taken ? q{} : $dbh->state;
}

sub _in_transaction {
    my ( $ctx, $code ) = @_;

    return $ctx->{schema}->txn_do($code);
}

sub _at {
    my ( $ctx, $timestamp ) = @_;

    $ctx->{clock}->iso8601($timestamp);
    $ctx->{clock}->epoch( _epoch($timestamp) );

    return;
}

sub _epoch {
    my ($timestamp) = @_;

    return GPForum::Service::Identity::Support->new->epoch_from_timestamp(
        $timestamp);
}

# A column of what a store answered: DBIx::Class hands back a row where a
# reused record comes back as a hash, and the stores read both this way.
sub _column {
    my ( $answer, $name ) = @_;

    return GPForum::Service::Identity::Support->new->column( $answer, $name );
}

sub _skipped {
    my ($answer) = @_;

    return ref $answer eq 'HASH' && $answer->{skipped} ? 1 : 0;
}

# Runs $code; just before its first statement matching $BEFORE{$what}
# reaches PostgreSQL, $rival runs on the second connection and commits.
# That is the window a concurrent request has between a store's look-up and
# its write.
sub _before {
    my ( $ctx, $what, $rival, $code ) = @_;

    my $pending = 1;
    my $result  = _traced(
        $ctx,
        sub {
            my ($statement) = @_;
            if ( $pending && $statement =~ $BEFORE{$what} ) {
                $pending = 0;
                $rival->( $ctx->{rival} );
            }
            return;
        },
        $code
    );
    ok( !$pending, "the rival ran before the $what" );

    return $result;
}

# $code's answer and the number of transactions it began.
sub _transactions {
    my ( $ctx, $code ) = @_;

    my $began = 0;
    my $dbh   = $ctx->{dbh};
    $dbh->{Callbacks} = {
        begin_work => sub {
            $began++;
            return;
        },
    };
    my $result = eval { return $code->() };
    my $error  = $EVAL_ERROR;
    delete $dbh->{Callbacks};
    croak $error if $error;

    return ( $result, $began );
}

# $code's answer and the statements it sent through DBIx::Class, in order.
sub _statements {
    my ( $ctx, $code ) = @_;

    my @sent;
    my $result = _traced(
        $ctx,
        sub {
            my ($statement) = @_;
            push @sent, $statement;
            return;
        },
        $code
    );

    return ( $result, \@sent );
}

sub _traced {
    my ( $ctx, $watch, $code ) = @_;

    my $storage = $ctx->{schema}->storage;
    $storage->debugcb(
        sub {
            my ( undef, $statement ) = @_;
            $watch->($statement);
            return;
        }
    );
    $storage->debug(1);
    my $result = eval { return $code->() };
    my $error  = $EVAL_ERROR;
    $storage->debug(0);
    $storage->debugcb(undef);
    croak $error if $error;

    return $result;
}

sub _version {
    my ( $ctx, $table, $key ) = @_;

    return _value( $ctx, $VERSION_SQL{$table}, $key );
}

sub _utc {
    my ( $ctx, $timestamp ) = @_;

    return _value( $ctx, $UTC_SQL, $timestamp );
}

sub _row {
    my ( $ctx, $sql, @bind ) = @_;

    return $ctx->{dbh}->selectrow_hashref( $sql, undef, @bind ) // {};
}

sub _value {
    my ( $ctx, $sql, @bind ) = @_;

    return scalar $ctx->{dbh}->selectrow_array( $sql, undef, @bind );
}

1;
