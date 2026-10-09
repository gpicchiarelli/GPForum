# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use English     qw(-no_match_vars);
use POSIX       qw(_exit strftime :sys_wait_h);
use Time::HiRes qw(sleep time);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Infrastructure::Id;
use GPForum::Schema;
use GPForum::Service::Identity::Store;
use GPForum::Service::Password;
use GPForum::Test::InterposingPassword;
use GPForum::Test::InterleavedClock;
use GPForum::Test::InterposingSessionToken;
use GPForum::Test::PgDatabase;
use GPForum::Test::RecordingPassword;
use GPForum::Test::SkewedClock;

our $VERSION = '0.001';

const my $PASSWORD      => 'correct horse battery staple';
const my $NEW_PASSWORD  => 'a brand new sufficiently long secret';
const my $WAIT_SECONDS  => 15;
const my $POLL_SECONDS  => 0.05;
const my $CHILD_FAILURE => 3;

# How far ahead of the reset's clock the login's runs: the reset reads its
# clock before it waits for the login, and the login stamps its session after
# that, in the same second or the next. Two seconds puts it in a later one on
# every run, not only when a second boundary falls in between.
const my $LOGIN_AHEAD => 2;
const my $HOUR        => 3_600;
const my $USER_SQL => join q{ },
  'INSERT INTO users (id, username, display_name, email_normalized,',
  q{password_hash, status, email_verified_at)},
  q{VALUES (?, ?, ?, ?, ?, 'active', now())};
const my $CREDENTIAL_SQL => join q{ },
  'INSERT INTO credentials (id, user_id, type, secret_hash, created_at)',
  q{VALUES (?, ?, 'password', ?, now() - interval '1 day')};
const my $SESSION_SQL => join q{ },
  'INSERT INTO sessions (session_id, user_id, session_hash, created_at,',
  q{last_seen_at, expires_at) VALUES (?, ?, ?, now() - interval '1 hour',},
  q{now() - interval '1 hour', now() + interval '1 day')};
const my $LIVE_SESSIONS_SQL => join q{ },
  'SELECT session_id FROM sessions',
  'WHERE user_id = ? AND revoked_at IS NULL ORDER BY session_id';
const my $SESSION_TIMES_SQL => join q{ },
  'SELECT revoked_at IS NOT NULL AND revoked_at >= created_at',
  'FROM sessions WHERE session_id = ?';
const my $REVOKE_SQL => join q{ },
  'UPDATE sessions SET revoked_at = created_at + interval \'1 second\'',
  'WHERE session_id = ?';
const my $REVOKED_AT_SQL =>
  'SELECT revoked_at - created_at FROM sessions WHERE session_id = ?';
const my $LOCK_WAITERS_SQL => join q{ },
  'SELECT count(*) FROM pg_stat_activity',
  q{WHERE datname = current_database() AND wait_event_type = 'Lock'};

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run against PostgreSQL';
}

# A password reset or change revokes the member's sessions. A login verifies
# the password with Argon2 outside any transaction and opens its session
# afterwards, so a reset that committed in between used to leave the login's
# session standing: whoever knew the old password kept an account the reset
# was meant to take back. The session is now opened only while the
# credential the login verified is still the member's active one, read under
# a lock the reset's rotation of that credential waits for.
my $database = GPForum::Test::PgDatabase->fresh;
my $ctx      = {
    database => $database,
    ids      => GPForum::Infrastructure::Id->new,
    rival    => _connect($database),
    schema   => $database->schema,
    secret   => GPForum::Service::Password->new->hash_password($PASSWORD),
};

_reset_between_verification_and_session($ctx);
_change_between_verification_and_session($ctx);
_reset_while_the_login_holds_the_credential($ctx);
_reset_while_two_logins_open($ctx);
_logout_on_a_clock_behind_the_login($ctx);
_logout_after_a_concurrent_revocation($ctx);
_unknown_account_still_costs_a_verification($ctx);

$ctx->{rival}->storage->disconnect;

done_testing();

# The reset commits on another connection after the login verified the old
# password and before it opened its session.
sub _reset_between_verification_and_session {
    my ($context) = @_;

    my $user  = _member( $context, 'resetter' );
    my $other = _session( $context, $user );
    my $raw   = _reset_token( $context, 'resetter' );
    my $reset;
    my $login = _login(
        $context,
        'resetter',
        sub {
            $reset = _identity( $context, $context->{rival} )
              ->reset_password( { password => $NEW_PASSWORD, token => $raw } );
        }
    );

    ok( $reset->{ok}, 'the reset completes in the gap' );
    ok( !$login->{ok},
        'a login that verified the replaced password is refused' )
      or diag( 'login opened session ' . ( $login->{session_id} // q{?} ) );
    is( $login->{error}, 'invalid_credentials',
        'and answered as a wrong password' );
    is_deeply( _live_sessions( $context, $user ),
        [], 'no session of the member survives the reset' )
      or diag(
        'live sessions after the reset: ' . join q{, },
        @{ _live_sessions( $context, $user ) }
      );
    isnt( $other, undef, 'the session open before the reset existed' );

    return;
}

# A change keeps the device that made it and revokes every other; a login
# that verified the old password in the gap is not another device kept.
sub _change_between_verification_and_session {
    my ($context) = @_;

    my $user = _member( $context, 'changer' );
    my $kept = _session( $context, $user );
    my $change;
    my $login = _login(
        $context,
        'changer',
        sub {
            $change =
              _identity( $context, $context->{rival} )->change_password(
                {
                    current_password => $PASSWORD,
                    keep_session_id  => $kept,
                    new_password     => $NEW_PASSWORD,
                    user_id          => $user,
                }
              );
        }
    );

    ok( $change->{ok}, 'the change completes in the gap' );
    ok( !$login->{ok},
        'a login that verified the changed password is refused' );
    is_deeply( _live_sessions( $context, $user ),
        [$kept], 'only the session that made the change stays live' );

    return;
}

# The login reaches its transaction first: the reset, on its own connection
# in another process, waits for the login to commit and then revokes the
# session the login opened. The reset read its clock before it waited, and
# the session was stamped later -- a second later here on every run: the
# revocation was given the reset's time, which the sessions table refuses
# before a session's creation, and the whole reset failed (two runs in five,
# whenever a second boundary fell in between) and left the session signed
# in.
sub _reset_while_the_login_holds_the_credential {
    my ($context) = @_;

    my $user   = _member( $context, 'holder' );
    my $raw    = _reset_token( $context, 'holder' );
    my $child  = {};
    my $tokens = GPForum::Test::InterposingSessionToken->new(
        interpose => sub {
            $child->{pid} = _reset_in_child( $context->{database}, $raw );
            _await_lock_wait( $context, $child );
        }
    );
    my $login = _identity(
        $context, $context->{schema},
        clock          => _ahead(),
        session_tokens => $tokens,
      )
      ->authenticate_login( { identifier => 'holder', password => $PASSWORD } );
    _reap($child);

    ok( $login->{ok}, 'the login that reached its transaction first opens' );
    ok( $child->{waited},
        'the reset waits for the login holding the credential' );
    is( $child->{status}, 0,
        'the reset then completes, though the session is a second younger' );
    is_deeply( _live_sessions( $context, $user ),
        [], 'and revokes the session the login opened' );
    ok( _revoked_after_creation( $context, $login->{session_id} ),
        'no earlier than the session was created' );

    return;
}

# A second login verifies the old password while the reset waits for the
# first, and opens its session while the first still holds the credential: a
# shared lock does not queue behind the reset's, so the reset waits for both
# and then revokes both.
sub _reset_while_two_logins_open {
    my ($context) = @_;

    my $user  = _member( $context, 'pair' );
    my $raw   = _reset_token( $context, 'pair' );
    my $child = {};
    my $gap_login;
    my $tokens = GPForum::Test::InterposingSessionToken->new(
        interpose => sub {
            $child->{pid} = _reset_in_child( $context->{database}, $raw );
            _await_lock_wait( $context, $child );
            $gap_login =
              _identity( $context, $context->{rival}, clock => _ahead() )
              ->authenticate_login(
                { identifier => 'pair', password => $PASSWORD } );
        }
    );
    my $first = _identity(
        $context, $context->{schema},
        clock          => _ahead(),
        session_tokens => $tokens,
    )->authenticate_login( { identifier => 'pair', password => $PASSWORD } );
    _reap($child);

    ok( $first->{ok} && $gap_login->{ok},
        'two logins open while the reset waits for the credential' );
    is( $child->{status}, 0, 'the reset completes after both' );
    is_deeply( _live_sessions( $context, $user ),
        [], 'and revokes both sessions' );

    return;
}

# The host that signs a member out can have a clock behind the one that
# signed them in. The logout gave the session its own clock's time, earlier
# than the session's creation, and died on the check constraint, leaving the
# member signed in.
sub _logout_on_a_clock_behind_the_login {
    my ($context) = @_;

    my $user = _member( $context, 'leaver' );
    my $login =
      _identity( $context, $context->{schema}, clock => _ahead() )
      ->authenticate_login( { identifier => 'leaver', password => $PASSWORD } );
    my ( $logout, $error );
    try {
        $logout =
          _identity( $context, $context->{rival} )
          ->revoke_session(
            { session_id => $login->{session_id}, user_id => $user } );
    }
    catch ($caught) {
        $error = $caught;
    };

    ok( $logout && $logout->{ok},
        'a logout on a clock behind the login signs the member out' )
      or diag( $error // 'no answer' );
    is_deeply( _live_sessions( $context, $user ),
        [], 'leaving no session signed in' );
    ok( _revoked_after_creation( $context, $login->{session_id} ),
        'revoked no earlier than it was created' );

    return;
}

# A revocation that commits between the logout's look-up and its write
# keeps its time: the logout answers skipped, as a second logout does. It
# used to write its own time over it.
sub _logout_after_a_concurrent_revocation {
    my ($context) = @_;

    my $user = _member( $context, 'twice' );
    my $session =
      _identity( $context, $context->{schema} )
      ->authenticate_login( { identifier => 'twice', password => $PASSWORD } )
      ->{session_id};
    my $clock = GPForum::Test::InterleavedClock->new(
        before_next_read => sub {
            $context->{rival}->storage->dbh->do( $REVOKE_SQL, undef, $session );
        },
        iso8601 => strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime( time + $HOUR ) ),
    );
    my ( $logout, $error );
    try {
        $logout = _identity( $context, $context->{schema}, clock => $clock )
          ->revoke_session( { session_id => $session, user_id => $user } );
    }
    catch ($caught) {
        $error = $caught;
    };

    ok(
        $logout && $logout->{ok} && $logout->{skipped},
        'a logout a concurrent revocation beat is skipped'
    ) or diag( $error // 'answered ' . join q{ }, %{ $logout || {} } );
    is(
        scalar $context->{schema}
          ->storage->dbh->selectrow_array( $REVOKED_AT_SQL, undef, $session ),
        '00:00:01',
        'and the revocation that landed first keeps its time'
    );

    return;
}

# The lock changed nothing for an account that does not exist: the answer
# still costs one Argon2 verification, against the decoy.
sub _unknown_account_still_costs_a_verification {
    my ($context) = @_;

    my $password = GPForum::Test::RecordingPassword->new;
    my $answer =
      _identity( $context, $context->{schema}, password => $password )
      ->authenticate_login(
        { identifier => 'nobody-here', password => $PASSWORD } );
    is_deeply(
        $password->verified,
        [ $password->decoy_hash ],
        'an unknown account still costs one verification, of the decoy'
    );
    is( $answer->{error}, 'invalid_credentials',
        'an unknown account is refused as a wrong password' );

    return;
}

sub _ahead {
    return GPForum::Test::SkewedClock->new( seconds => $LOGIN_AHEAD );
}

# The child's exit status, once it has finished.
sub _reap {
    my ($child) = @_;

    if ( !exists $child->{status} ) {
        waitpid $child->{pid}, 0;
        $child->{status} = WEXITSTATUS($CHILD_ERROR);
    }

    return;
}

sub _revoked_after_creation {
    my ( $context, $session ) = @_;

    return
      scalar $context->{schema}
      ->storage->dbh->selectrow_array( $SESSION_TIMES_SQL, undef, $session );
}

sub _login {
    my ( $context, $name, $interpose ) = @_;

    my $password =
      GPForum::Test::InterposingPassword->new( interpose => $interpose );

    return _identity( $context, $context->{schema}, password => $password )
      ->authenticate_login( { identifier => $name, password => $PASSWORD } );
}

# The reset in a process of its own, on a connection of its own: it blocks
# there while the parent's transaction holds the lock it needs.
sub _reset_in_child {
    my ( $database_arg, $raw ) = @_;

    my $pid = fork;
    if ( !defined $pid ) {
        BAIL_OUT("fork: $OS_ERROR");
    }
    if ($pid) {
        return $pid;
    }

    my $code = $CHILD_FAILURE;
    try {
        my $schema = _connect($database_arg);
        my $result =
          GPForum::Service::Identity::Store->new( schema => $schema )
          ->reset_password( { password => $NEW_PASSWORD, token => $raw } );
        $code = $result->{ok} ? 0 : 1;
        $schema->storage->disconnect;
    }
    catch ($error) {
        print {*STDERR} "reset in child: $error\n"
          or $code = $CHILD_FAILURE;
    };
    return _exit($code);
}

# Notes in %{$child} whether some backend came to wait on a lock before the
# child finished, and the child's exit status when it finished first.
sub _await_lock_wait {
    my ( $context, $child ) = @_;

    my $dbh      = $context->{rival}->storage->dbh;
    my $deadline = time + $WAIT_SECONDS;
    $child->{waited} = 0;
    while ( time < $deadline ) {
        my ($waiting) = $dbh->selectrow_array($LOCK_WAITERS_SQL);
        if ($waiting) {
            $child->{waited} = 1;
            return;
        }
        if ( waitpid( $child->{pid}, WNOHANG ) == $child->{pid} ) {
            $child->{status} = WEXITSTATUS($CHILD_ERROR);
            return;
        }
        sleep $POLL_SECONDS;
    }

    return;
}

sub _identity {
    my ( $context, $schema, %options ) = @_;

    return GPForum::Service::Identity::Store->new(
        id_service => $context->{ids},
        schema     => $schema,
        %options,
    );
}

sub _reset_token {
    my ( $context, $name ) = @_;

    my $request = _identity( $context, $context->{rival} )
      ->request_password_reset( { identifier => $name } );

    return $request->{token}{raw_token};
}

sub _member {
    my ( $context, $name ) = @_;

    my $id  = $context->{ids}->uuid;
    my $dbh = $context->{schema}->storage->dbh;
    $dbh->do( $USER_SQL, undef, $id, $name, ucfirst $name,
        "$name\@example.test", $context->{secret} );
    $dbh->do(
        $CREDENTIAL_SQL, undef, $context->{ids}->uuid,
        $id,             $context->{secret}
    );

    return $id;
}

sub _session {
    my ( $context, $user ) = @_;

    my $id = $context->{ids}->uuid;
    $context->{schema}
      ->storage->dbh->do( $SESSION_SQL, undef, $id, $user, "hash-$id" );

    return $id;
}

sub _live_sessions {
    my ( $context, $user ) = @_;

    return $context->{schema}
      ->storage->dbh->selectcol_arrayref( $LIVE_SESSIONS_SQL, undef, $user );
}

sub _connect {
    my ($database_arg) = @_;

    local $ENV{GPFORUM_DATABASE_DSN} = $database_arg->dsn;

    return GPForum::Schema->connect_from_config(
        GPForum::Config->from_environment );
}

1;
