# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use English     qw(-no_match_vars);
use POSIX       qw(_exit :sys_wait_h);
use Time::HiRes qw(sleep time);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Infrastructure::Id;
use GPForum::Schema;
use GPForum::Service::Identity::Store;
use GPForum::Service::Password;
use GPForum::Test::HoldingSessionStore;
use GPForum::Test::InterposingPassword;
use GPForum::Test::PgDatabase;
use GPForum::Test::SkewedClock;

our $VERSION = '0.001';

const my $OLD_PASSWORD    => 'correct horse battery staple';
const my $MEMBER_PASSWORD => 'the member reset the password to this';
const my $OTHER_PASSWORD  => 'whoever knew the old one chose this';
const my $WAIT_SECONDS    => 15;
const my $POLL_SECONDS    => 0.05;
const my $CHILD_FAILURE   => 3;
const my $AHEAD           => 2;
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
const my $ACTIVE_SQL => join q{ },
  'SELECT count(*) FROM credentials',
  q{WHERE user_id = ? AND type = 'password' AND revoked_at IS NULL};
const my $USER_HASH_SQL => 'SELECT password_hash FROM users WHERE id = ?';
const my $LOCK_WAITERS_SQL => join q{ },
  'SELECT count(*) FROM pg_stat_activity',
  q{WHERE datname = current_database() AND wait_event_type = 'Lock'};

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run against PostgreSQL';
}

# A password change verifies the current password before its transaction,
# and a reset or a change rotated whatever credential it found once it had
# the lock. Racing each other, the one that came second won or lied: a change
# verified against the old password overwrote the reset that had just taken
# the account back, a reset that waited for a change answered ok and left the
# change's password, and a change that waited for another reported success
# with a password it never stored. Each case runs the two on two
# connections, the second one in the first one's window.
my $database = GPForum::Test::PgDatabase->fresh;
my $ctx      = {
    database => $database,
    hasher   => GPForum::Service::Password->new,
    ids      => GPForum::Infrastructure::Id->new,
    rival    => _connect($database),
    schema   => $database->schema,
};
$ctx->{secret} = $ctx->{hasher}->hash_password($OLD_PASSWORD);

_change_verified_before_a_reset($ctx);
_reset_waiting_for_a_change($ctx);
_change_waiting_for_a_change($ctx);

$ctx->{rival}->storage->disconnect;

done_testing();

# Whoever knew the old password -- the reason for the reset -- asks for a
# change; the member's reset commits after the change verified the old
# password and before its transaction.
sub _change_verified_before_a_reset {
    my ($context) = @_;

    my $user = _member( $context, 'retaken' );
    my $kept = _session( $context, $user );
    my $raw  = _reset_token( $context, 'retaken' );
    my $reset;
    my $verifier = GPForum::Test::InterposingPassword->new(
        interpose => sub {
            $reset =
              _identity( $context, $context->{rival} )
              ->reset_password(
                { password => $MEMBER_PASSWORD, token => $raw } );
        }
    );
    my $change =
      _identity( $context, $context->{schema}, password => $verifier )
      ->change_password(
        {
            current_password => $OLD_PASSWORD,
            keep_session_id  => $kept,
            new_password     => $OTHER_PASSWORD,
            user_id          => $user,
        }
      );

    ok( $reset->{ok}, 'the reset commits in the gap' );
    is( $change->{error}, 'invalid_current_password',
        'the change verified against the replaced password is refused' );
    ok( _signs_in( $context, 'retaken', $MEMBER_PASSWORD ),
        'the password the reset set signs in' );
    ok(
        !_signs_in( $context, 'retaken', $OTHER_PASSWORD ),
        'the one the change asked for does not'
    );

    return;
}

# The change holds the member's credential, stamped two seconds ahead, while
# the reset, in another process on its own connection, waits for it.
sub _reset_waiting_for_a_change {
    my ($context) = @_;

    my $user     = _member( $context, 'waiter' );
    my $raw      = _reset_token( $context, 'waiter' );
    my $child    = {};
    my $sessions = _holding_session_store(
        $context,
        sub {
            $child->{pid} = _in_child(
                $context->{database},
                sub ($identity) {
                    return $identity->reset_password(
                        { password => $MEMBER_PASSWORD, token => $raw } );
                }
            );
            _await_lock_wait( $context, $child );
        }
    );
    my $change = _identity(
        $context, $context->{schema},
        clock         => GPForum::Test::SkewedClock->new( seconds => $AHEAD ),
        session_store => $sessions,
    )->change_password(
        {
            current_password => $OLD_PASSWORD,
            new_password     => $OTHER_PASSWORD,
            user_id          => $user,
        }
    );
    _reap($child);

    ok( $change->{ok},    'the change that held the credential first commits' );
    ok( $child->{waited}, 'the reset waits for it' );
    is( $child->{status}, 0,
        'and then completes, on a clock behind the credential it replaces' );
    ok( _signs_in( $context, 'waiter', $MEMBER_PASSWORD ),
        'the password the reset set signs in' );
    ok(
        !_signs_in( $context, 'waiter', $OTHER_PASSWORD ),
        'the one the change set before it does not'
    );
    is( _active_credentials( $context, $user ),
        1, 'one active password credential' );

    return;
}

# Two changes verified the same current password; the second waits for the
# first's transaction.
sub _change_waiting_for_a_change {
    my ($context) = @_;

    my $user     = _member( $context, 'twice' );
    my $child    = {};
    my $sessions = _holding_session_store(
        $context,
        sub {
            $child->{pid} = _in_child(
                $context->{database},
                sub ($identity) {
                    my $refused = $identity->change_password(
                        {
                            current_password => $OLD_PASSWORD,
                            new_password     => $OTHER_PASSWORD,
                            user_id          => $user,
                        }
                    );
                    return { ok => ( $refused->{error} // q{} ) eq
                          'invalid_current_password' };
                }
            );
            _await_lock_wait( $context, $child );
        }
    );
    my $first =
      _identity( $context, $context->{schema}, session_store => $sessions )
      ->change_password(
        {
            current_password => $OLD_PASSWORD,
            new_password     => $MEMBER_PASSWORD,
            user_id          => $user,
        }
      );
    _reap($child);

    ok( $first->{ok},     'the first change commits' );
    ok( $child->{waited}, 'the second waits for it' );
    is( $child->{status}, 0,
        'and is refused: its current password is no longer current' );
    ok(
        _signs_in( $context, 'twice', $MEMBER_PASSWORD ),
        'the first change\'s password signs in'
    );
    ok(
        $context->{hasher}->verify_password(
            $MEMBER_PASSWORD,
            scalar $context->{schema}
              ->storage->dbh->selectrow_array( $USER_HASH_SQL, undef, $user )
        ),
        'and is the one the account row holds'
    );

    return;
}

# A session store that runs the code once, before it revokes: the rotation
# that precedes the revocation in the same transaction holds the credential
# then.
sub _holding_session_store {
    my ( $context, $code ) = @_;

    return GPForum::Test::HoldingSessionStore->new(
        before_revoke => $code,
        id_service    => $context->{ids},
        schema        => $context->{schema},
    );
}

# The work in a process of its own, on a connection of its own; the child
# exits 0 when the work answers ok.
sub _in_child {
    my ( $database_arg, $work ) = @_;

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
          $work->(
            GPForum::Service::Identity::Store->new( schema => $schema ) );
        $code = $result->{ok} ? 0 : 1;
        $schema->storage->disconnect;
    }
    catch ($error) {
        print {*STDERR} "child: $error\n"
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

sub _reap {
    my ($child) = @_;

    if ( !exists $child->{status} ) {
        waitpid $child->{pid}, 0;
        $child->{status} = WEXITSTATUS($CHILD_ERROR);
    }

    return;
}

sub _signs_in {
    my ( $context, $name, $password ) = @_;

    return _identity( $context, $context->{schema} )
      ->authenticate_login( { identifier => $name, password => $password } )
      ->{ok};
}

sub _active_credentials {
    my ( $context, $user ) = @_;

    return
      scalar $context->{schema}
      ->storage->dbh->selectrow_array( $ACTIVE_SQL, undef, $user );
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

sub _connect {
    my ($database_arg) = @_;

    local $ENV{GPFORUM_DATABASE_DSN} = $database_arg->dsn;

    return GPForum::Schema->connect_from_config(
        GPForum::Config->from_environment );
}

1;
