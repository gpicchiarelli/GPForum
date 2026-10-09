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
use GPForum::Service::Privacy::DeletionWorkflow;
use GPForum::Test::InterposingSessionToken;
use GPForum::Test::PgDatabase;
use GPForum::Test::SkewedClock;

our $VERSION = '0.001';

const my $PASSWORD      => 'correct horse battery staple';
const my $AHEAD         => 2;
const my $A_SECOND_AGO  => -1;
const my $WAIT_SECONDS  => 15;
const my $POLL_SECONDS  => 0.05;
const my $CHILD_FAILURE => 3;
const my $USER_SQL => join q{ },
  'INSERT INTO users (id, username, display_name, email_normalized,',
  q{password_hash, status, email_verified_at)},
  q{VALUES (?, ?, ?, ?, ?, 'active', now())};
const my $CREDENTIAL_SQL => join q{ },
  'INSERT INTO credentials (id, user_id, type, secret_hash, created_at)',
  q{VALUES (?, ?, 'password', ?, now() + ? * interval '1 second')};
const my $SESSION_SQL => join q{ },
  'INSERT INTO sessions (session_id, user_id, session_hash, created_at,',
  q{last_seen_at, expires_at) VALUES (?, ?, ?,},
  q{now() + ? * interval '1 second', now() + ? * interval '1 second',},
  q{now() + interval '1 day')};
const my $STATUS_SQL => 'SELECT status FROM users WHERE id = ?';
const my $LIVE_SQL => join q{ },
  'SELECT (SELECT count(*) FROM sessions',
  ' WHERE user_id = ? AND revoked_at IS NULL)',
  '+ (SELECT count(*) FROM credentials',
  ' WHERE user_id = ? AND revoked_at IS NULL)';
const my $BEFORE_CREATION_SQL => join q{ },
  'SELECT (SELECT count(*) FROM sessions',
  ' WHERE user_id = ? AND revoked_at < created_at)',
  '+ (SELECT count(*) FROM credentials',
  ' WHERE user_id = ? AND revoked_at < created_at)';
const my $LOCK_WAITERS_SQL => join q{ },
  'SELECT count(*) FROM pg_stat_activity',
  q{WHERE datname = current_database() AND wait_event_type = 'Lock'};

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run against PostgreSQL';
}

# An erasure anonymizes the member and revokes their credentials and
# sessions in one transaction. It took the account row first and the
# credentials after, while a login opening a session holds the credential
# and then needs the account row: the two deadlocked, PostgreSQL aborted the
# erasure, and the login's session stayed. And it revoked every row at its
# own time, which the revoked_after_created checks refuse for a row stamped
# later -- a session the erasure waited for, a credential a host ahead
# stamped -- so the erasure failed.
my $database = GPForum::Test::PgDatabase->fresh;
my $ctx      = {
    database => $database,
    ids      => GPForum::Infrastructure::Id->new,
    rival    => _connect($database),
    schema   => $database->schema,
    secret   => GPForum::Service::Password->new->hash_password($PASSWORD),
};
$ctx->{staff} = _member( $ctx, 'staff' );

_erasure_while_a_login_holds_the_credential($ctx);
_erasure_behind_the_rows_it_revokes($ctx);

$ctx->{rival}->storage->disconnect;

done_testing();

# The login, on a clock two seconds ahead, holds the member's credential
# while the erasure, in another process on its own connection, starts.
sub _erasure_while_a_login_holds_the_credential {
    my ($context) = @_;

    my $user   = _member( $context, 'leaving' );
    my $job    = _approved_erasure( $context, $user );
    my $child  = {};
    my $tokens = GPForum::Test::InterposingSessionToken->new(
        interpose => sub {
            $child->{pid} =
              _erase_in_child( $context->{database}, $job, $context->{staff} );
            _await_lock_wait( $context, $child );
        }
    );
    my ( $login, $error );
    try {
        $login = GPForum::Service::Identity::Store->new(
            clock      => GPForum::Test::SkewedClock->new( seconds => $AHEAD ),
            id_service => $context->{ids},
            schema     => $context->{schema},
            session_tokens => $tokens,
          )
          ->authenticate_login(
            { identifier => 'leaving', password => $PASSWORD } );
    }
    catch ($caught) {
        $error = $caught;
    };
    _reap($child);

    ok( $login && $login->{ok}, 'the login holding the credential opens' )
      or diag( $error // 'refused' );
    ok( $child->{waited}, 'the erasure waits for it' );
    is( $child->{status}, 0, 'and then completes, without a deadlock' );
    _erased( $context, $user, 'the member the login signed in' );

    return;
}

# The member's credential and session were stamped by a clock two seconds
# ahead of the erasure's.
sub _erasure_behind_the_rows_it_revokes {
    my ($context) = @_;

    my $user = _member( $context, 'ahead', $AHEAD );
    _session( $context, $user, $AHEAD );
    my $job = _approved_erasure( $context, $user );
    my ( $completed, $error );
    try {
        $completed = _deletion( $context, $context->{schema} )
          ->complete_job( $job, $context->{staff} );
    }
    catch ($caught) {
        $error = $caught;
    };

    ok( $completed && $completed->{ok},
        'an erasure on a clock behind the rows it revokes completes' )
      or diag( $error // 'not completed' );
    _erased( $context, $user, 'the member whose rows were stamped ahead' );

    return;
}

sub _erased {
    my ( $context, $user, $who ) = @_;

    my $dbh = $context->{schema}->storage->dbh;
    is( scalar $dbh->selectrow_array( $STATUS_SQL, undef, $user ),
        'deleted', "$who is erased" );
    is( scalar $dbh->selectrow_array( $LIVE_SQL, undef, $user, $user ),
        0, 'with no session or credential left live' );
    is(
        scalar $dbh->selectrow_array( $BEFORE_CREATION_SQL, undef, $user,
            $user ),
        0,
        'and none revoked before it was created'
    );

    return;
}

sub _approved_erasure {
    my ( $context, $user ) = @_;

    my $workflow = _deletion( $context, $context->{rival} );
    my $request  = $workflow->request_deletion(
        {
            reason            => 'user requested account deletion',
            request_type      => 'anonymize',
            requester_user_id => $user,
            resource_id       => $user,
            resource_type     => 'user',
        }
    );
    my $approved = $workflow->approve_request( $request->{deletion_request_id},
        $context->{staff}, 'verified the request' );

    return $approved->{job}{erasure_job_id};
}

# The erasure in a process of its own, on a connection of its own: it blocks
# there while the parent's transaction holds what it needs.
sub _erase_in_child {
    my ( $database_arg, $job, $staff ) = @_;

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
        my $completed =
          GPForum::Service::Privacy::DeletionWorkflow->new( schema => $schema )
          ->complete_job( $job, $staff );
        $code = $completed && $completed->{ok} ? 0 : 1;
        $schema->storage->disconnect;
    }
    catch ($error) {
        print {*STDERR} "erasure in child: $error\n"
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

sub _deletion {
    my ( $context, $schema ) = @_;

    return GPForum::Service::Privacy::DeletionWorkflow->new(
        id_service => $context->{ids},
        schema     => $schema,
    );
}

sub _member {
    my ( $context, $name, $ahead ) = @_;

    my $id  = $context->{ids}->uuid;
    my $dbh = $context->{schema}->storage->dbh;
    $dbh->do( $USER_SQL, undef, $id, $name, ucfirst $name,
        "$name\@example.test", $context->{secret} );
    $dbh->do( $CREDENTIAL_SQL, undef, $context->{ids}->uuid,
        $id, $context->{secret}, $ahead // $A_SECOND_AGO );

    return $id;
}

sub _session {
    my ( $context, $user, $ahead ) = @_;

    my $id = $context->{ids}->uuid;
    $context->{schema}->storage->dbh->do( $SESSION_SQL, undef, $id, $user,
        "hash-$id", $ahead, $ahead );

    return $id;
}

sub _connect {
    my ($database_arg) = @_;

    local $ENV{GPFORUM_DATABASE_DSN} = $database_arg->dsn;

    return GPForum::Schema->connect_from_config(
        GPForum::Config->from_environment );
}

1;
