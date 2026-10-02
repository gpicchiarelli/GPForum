# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(decode_json encode_json);
use POSIX         qw(_exit);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Admin::PermissionReview;
use GPForum::Service::Admin::RoleBindingStore;
use GPForum::Service::Admin::RoleCatalog;
use GPForum::Test::FixedClock;
use GPForum::Test::PgDatabase;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $LOCK_TIMEOUT_MS    => 10_000;
const my $IDLE_TIMEOUT_MS    => 30_000;
const my $BLOCK_POLLS        => 200;
const my $BLOCK_POLL_SECONDS => 0.05;
const my $FIRST_REVOKED_AT   => '2026-10-01T09:00:00Z';
const my $SECOND_REVOKED_AT  => '2026-10-01T09:05:00Z';
const my $ATTACHED           => 'role_permission.attached';
const my $REVOKED            => 'role_binding.revoked';
const my $CREATED            => 'role_binding.created';
const my $PROBE_RESOURCE     => 'role_admin_probe';
const my @PROBE_ACTIONS      => qw(kept lost raced spelled);
const my $REVIEW_LIMIT       => 2;
const my $SEED_USERS_SQL => 'SELECT id FROM users ORDER BY username LIMIT 2';

# Blocked by the holder on a row: a transaction id or a tuple lock. Every
# write here also queues on the audit chain's advisory lock, so a backend
# merely blocked by the holder could be waiting there instead.
const my $ROW_WAIT_SQL => join q{ },
  'SELECT count(*) FROM pg_stat_activity',
  'WHERE ? = ANY (pg_blocking_pids(pid))',
  q{AND wait_event IN ('transactionid', 'tuple')};
const my $REVOKED_AT_SQL => join q{ },
  'SELECT count(*) FROM role_bindings',
  'WHERE binding_id = ? AND revoked_at = ?::timestamptz';
const my $ENTRIES_SQL =>
  'SELECT count(*) FROM audit_log WHERE action = ? AND target_id = ?';
const my $REVOKED_BY_SQL => join q{ },
  'SELECT actor_id FROM audit_log WHERE action = ? AND target_id = ?';
const my $PAIR_ENTRIES_SQL => join q{ },
  'SELECT count(*) FROM audit_log WHERE action = ? AND target_id = ?',
  q{AND metadata->>'permission_id' = ?};
const my $SPELLED_ENTRIES_SQL => join q{ },
  'SELECT count(*) FROM audit_log WHERE action = ? AND target_id = ?',
  q{AND (metadata->>'permission_id')::uuid = ?::uuid};
const my $LOSE_PAIR_ENTRY_SQL => join q{ },
  'DELETE FROM audit_log WHERE action = ? AND target_id = ?',
  q{AND metadata->>'permission_id' = ?};
const my $PAIR_ROWS_SQL => join q{ },
  'SELECT count(*) FROM role_permissions',
  'WHERE role_id = ? AND permission_id = ?';
const my $ACTIVE_BINDINGS_SQL => join q{ },
  'SELECT count(*) FROM role_bindings',
  'WHERE user_id = ? AND role_id = ? AND revoked_at IS NULL';

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the role admin test';
}

local $ENV{GPFORUM_DATABASE_LOCK_TIMEOUT_MS} = $LOCK_TIMEOUT_MS;

# The first revocation sits idle in its transaction while the test polls for
# the second one's wait; the default timeout would end it first.
local $ENV{GPFORUM_DATABASE_IDLE_IN_TRANSACTION_TIMEOUT_MS} = $IDLE_TIMEOUT_MS;
local $ENV{GPFORUM_MINION_ENABLED}                          = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED}               = 0;

my $database = GPForum::Test::PgDatabase->fresh( seed => 1 );
local $ENV{GPFORUM_DATABASE_DSN} = $database->dsn;
my $dbh = $database->dbh;

my $case = _context();
_revocations_serialise($case);
_lost_attachment_entry_completed($case);
_spelled_attachment_counts_as_audited($case);
_attachment_race_keeps_one_entry($case);
_grant_race_keeps_one_binding($case);
_review_reads_what_the_stores_wrote($case);

done_testing();

sub _context {
    my ( $admin_id, $member_id ) =
      @{ $dbh->selectcol_arrayref($SEED_USERS_SQL) };
    ok( $admin_id && $member_id, 'the seed provides two users' );

    my $schema  = $database->schema;
    my $catalog = _catalog($schema);
    my $role    = $schema->txn_do(
        sub {
            return $catalog->create_role(
                {
                    actor_user_id => $admin_id,
                    description   => 'Role administration probe',
                    name          => 'role-admin-probe',
                }
            );
        }
    );
    my %permission_ids;
    for my $action (@PROBE_ACTIONS) {
        my $permission = $schema->txn_do(
            sub {
                return $catalog->create_permission(
                    {
                        action        => $action,
                        actor_user_id => $admin_id,
                        name          => "$PROBE_RESOURCE.$action",
                        resource_type => $PROBE_RESOURCE,
                    }
                );
            }
        );
        $permission_ids{$action} = $permission->{permission_id};
    }

    return {
        admin_id       => $admin_id,
        member_id      => $member_id,
        permission_ids => \%permission_ids,
        role_id        => $role->{role_id},
        schema         => $schema,
    };
}

# Two revocations of one binding. The first holds its transaction open after
# revoking; the second must queue on the binding's row and, once the first
# commits, read its revoked_at and answer idempotently. Read without the row
# lock, the second saw the binding active, overwrote revoked_at with its own
# time and recorded a second revocation audit row.
sub _revocations_serialise {
    my ($ctx) = @_;

    my $bound = $ctx->{schema}->txn_do(
        sub {
            return _store( $ctx->{schema} )->bind_role(
                {
                    actor_user_id => $ctx->{admin_id},
                    resource_id   => undef,
                    resource_type => 'global',
                    role_id       => $ctx->{role_id},
                    space_id      => undef,
                    user_id       => $ctx->{member_id},
                }
            );
        }
    );
    my $binding_id = $bound->{binding}{binding_id};
    ok( $binding_id, 'the member is granted the role' );

    my $holding =
      _spawn( sub { return _hold_revocation( $ctx, $binding_id, @_ ) } );
    my $holder  = _await_ready($holding);
    my $waiting = _spawn(
        sub {
            return _store( GPForum::Test::PostgresHarness::connect_schema(),
                $SECOND_REVOKED_AT )
              ->revoke_binding( $binding_id, $ctx->{member_id} );
        }
    );
    ok( _await_row_wait( $holder->{pid} ),
        q{the second revocation waits on the first one's row lock} );
    _release($holding);

    my $holding_outcome = _collect($holding);
    my $waiting_outcome = _collect($waiting);
    ok( $holding_outcome->{ok}, 'the first revocation finishes' )
      or diag( $holding_outcome->{error} // 'missing error' );
    ok( $waiting_outcome->{ok}, 'the second revocation finishes' )
      or diag( $waiting_outcome->{error} // 'missing error' );
    ok( !$holding_outcome->{result}{idempotent}, 'the first one revokes' );
    ok( $waiting_outcome->{result}{idempotent},
        'the second one reads the committed revocation and reports it' );
    is(
        scalar $dbh->selectrow_array(
            $REVOKED_AT_SQL, undef, $binding_id, $FIRST_REVOKED_AT
        ),
        1,
        'the binding keeps the first revocation time'
    );
    is(
        scalar $dbh->selectrow_array( $ENTRIES_SQL, undef, $REVOKED,
            $binding_id ),
        1,
        'one revocation audit row is written'
    );
    is_deeply(
        $dbh->selectcol_arrayref(
            $REVOKED_BY_SQL, undef, $REVOKED, $binding_id
        ),
        [ $ctx->{admin_id} ],
        'and it names the first revoker'
    );

    return;
}

sub _hold_revocation {
    my ( $ctx, $binding_id, $ready, $await_go ) = @_;

    my $schema = GPForum::Test::PostgresHarness::connect_schema();
    my ($pid) =
      $schema->storage->dbh->selectrow_array('SELECT pg_backend_pid()');
    $schema->txn_begin;
    my $revoked = _store( $schema, $FIRST_REVOKED_AT )
      ->revoke_binding( $binding_id, $ctx->{admin_id} );
    $ready->( { pid => $pid } );
    $await_go->();
    $schema->txn_commit;

    return $revoked;
}

# An attachment's audit entry targets the role and names the permission only
# in its metadata. With one attachment of the role audited and the other's
# entry lost, attaching the second again must write its entry: matched on
# the role alone, the first one's entry passed for it.
sub _lost_attachment_entry_completed {
    my ($ctx) = @_;

    my $kept = $ctx->{permission_ids}{kept};
    my $lost = $ctx->{permission_ids}{lost};
    _attach( $ctx, $kept );
    _attach( $ctx, $lost );
    $dbh->do( $LOSE_PAIR_ENTRY_SQL, undef, $ATTACHED, $ctx->{role_id}, $lost );
    is( _pair_entries( $ctx, $lost ),
        0, 'one attachment of the role has lost its audit entry' );

    my $again = _attach( $ctx, $lost );
    ok( $again->{idempotent},
        'attaching that pair again returns the existing attachment' );
    is( _pair_entries( $ctx, $lost ),
        1,
        q{its entry is written although the role's other attachment has one} );
    is( _pair_entries( $ctx, $kept ),
        1, 'the other attachment keeps its single entry' );

    _attach( $ctx, $kept );
    _attach( $ctx, $lost );
    is( _pair_entries( $ctx, $kept ) + _pair_entries( $ctx, $lost ),
        2, 'attaching audited pairs again writes nothing' );

    return;
}

# The entry's metadata keeps the ids as the command spelled them, while
# PostgreSQL reads a uuid in upper case, in braces or without its hyphens and
# hands back its canonical form. Attached again, such a pair is already
# audited: compared as lower-cased text, its entry did not count and every
# repeat wrote another.
sub _spelled_attachment_counts_as_audited {
    my ($ctx) = @_;

    my $spelled = $ctx->{permission_ids}{spelled};
    my $schema  = $ctx->{schema};
    my $first   = $schema->txn_do(
        sub {
            return _catalog($schema)->attach_permission(
                {
                    actor_user_id => $ctx->{admin_id},
                    permission_id => $spelled =~ tr/-//dr,
                    role_id       => '{' . uc( $ctx->{role_id} ) . '}',
                }
            );
        }
    );
    ok( !$first->{idempotent},
        'a pair spelled in braces and without hyphens attaches' );
    is( _spelled_entries( $ctx, $spelled ), 1, 'with its audit entry' );

    my $again = _attach( $ctx, $spelled );
    ok( $again->{idempotent},
        'attaching it again in canonical form returns the attachment' );
    is( _spelled_entries( $ctx, $spelled ), 1, 'and writes no second entry' );

    return;
}

sub _spelled_entries {
    my ( $ctx, $permission_id ) = @_;

    return
      scalar $dbh->selectrow_array( $SPELLED_ENTRIES_SQL, undef, $ATTACHED,
        $ctx->{role_id}, $permission_id );
}

# Two first attachments of one pair at once: the loser of the primary key
# finds the winner's row and its entry, and adds neither.
sub _attachment_race_keeps_one_entry {
    my ($ctx) = @_;

    my $raced    = $ctx->{permission_ids}{raced};
    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            my $schema   = GPForum::Test::PostgresHarness::connect_schema();
            my $attached = $schema->txn_do(
                sub {
                    return _catalog($schema)
                      ->attach_permission( _pair( $ctx, $raced ) );
                }
            );
            return { idempotent => $attached->{idempotent} ? 1 : 0 };
        }
    );
    is(
        scalar( grep { $_->{ok} } @outcomes ),
        scalar @outcomes,
        'every racing attachment finishes'
    );
    is( scalar( grep { !$_->{result}{idempotent} } @outcomes ),
        1, 'exactly one of them attaches' );
    is(
        scalar $dbh->selectrow_array(
            $PAIR_ROWS_SQL, undef, $ctx->{role_id}, $raced
        ),
        1,
        'the raced pair has one row'
    );
    is( _pair_entries( $ctx, $raced ), 1, 'and one audit entry' );

    return;
}

# Two grants of one scope at once: the partial unique index on active
# bindings decides, and the loser returns the winner's binding.
sub _grant_race_keeps_one_binding {
    my ($ctx) = @_;

    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            my $schema = GPForum::Test::PostgresHarness::connect_schema();
            my $bound  = $schema->txn_do(
                sub {
                    return _store($schema)->bind_role(
                        {
                            actor_user_id => $ctx->{member_id},
                            resource_id   => undef,
                            resource_type => 'global',
                            role_id       => $ctx->{role_id},
                            space_id      => undef,
                            user_id       => $ctx->{admin_id},
                        }
                    );
                }
            );
            return {
                binding_id => $bound->{binding}{binding_id},
                idempotent => $bound->{idempotent} ? 1 : 0,
            };
        }
    );
    is(
        scalar( grep { $_->{ok} } @outcomes ),
        scalar @outcomes,
        'every racing grant finishes'
    );
    is( scalar( grep { !$_->{result}{idempotent} } @outcomes ),
        1, 'exactly one of them creates the binding' );
    my %binding_ids = map { $_->{result}{binding_id} => 1 } @outcomes;
    is( scalar keys %binding_ids, 1, 'both answer with the same binding' );
    is(
        scalar $dbh->selectrow_array(
            $ACTIVE_BINDINGS_SQL, undef, $ctx->{admin_id}, $ctx->{role_id}
        ),
        1,
        'one active binding is stored'
    );
    is(
        scalar $dbh->selectrow_array(
            $ENTRIES_SQL, undef, $CREATED, keys %binding_ids
        ),
        1,
        'with one creation audit row'
    );

    return;
}

# The read side, against what the stores above left: the member's revoked
# binding is gone from their roles, the admin's raced one is listed, and the
# role lists its four permissions in id order.
sub _review_reads_what_the_stores_wrote {
    my ($ctx) = @_;

    my $review =
      GPForum::Service::Admin::PermissionReview->new(
        schema => $ctx->{schema} );
    is( _probe_bindings( $review, $ctx, $ctx->{member_id} ),
        0, 'a revoked binding is not among the member roles' );
    is( _probe_bindings( $review, $ctx, $ctx->{admin_id} ),
        1, 'an active binding is' );

    my @permission_ids =
      map { $_->get_column('permission_id') }
      @{ $review->permissions_for_role( $ctx->{role_id}, {} ) };
    is_deeply(
        \@permission_ids,
        [ sort values %{ $ctx->{permission_ids} } ],
        'the role lists its permissions in id order'
    );
    is(
        scalar @{
            $review->permissions_for_role( $ctx->{role_id},
                { limit => $REVIEW_LIMIT } )
        },
        $REVIEW_LIMIT,
        'and stops at the limit'
    );

    return;
}

sub _probe_bindings {
    my ( $review, $ctx, $user_id ) = @_;

    my @bindings =
      grep { $_->get_column('role_id') eq $ctx->{role_id} }
      @{ $review->roles_for_user( $user_id, {} ) };

    return scalar @bindings;
}

sub _attach {
    my ( $ctx, $permission_id ) = @_;

    my $schema = $ctx->{schema};

    return $schema->txn_do(
        sub {
            return _catalog($schema)
              ->attach_permission( _pair( $ctx, $permission_id ) );
        }
    );
}

sub _pair {
    my ( $ctx, $permission_id ) = @_;

    return {
        actor_user_id => $ctx->{admin_id},
        permission_id => $permission_id,
        role_id       => $ctx->{role_id},
    };
}

sub _pair_entries {
    my ( $ctx, $permission_id ) = @_;

    return
      scalar $dbh->selectrow_array( $PAIR_ENTRIES_SQL, undef, $ATTACHED,
        $ctx->{role_id}, $permission_id );
}

sub _catalog {
    my ($schema) = @_;

    return GPForum::Service::Admin::RoleCatalog->new( schema => $schema );
}

sub _store {
    my ( $schema, $now ) = @_;

    my %clock =
      $now
      ? ( clock => GPForum::Test::FixedClock->new( iso8601 => $now ) )
      : ();

    return GPForum::Service::Admin::RoleBindingStore->new(
        schema => $schema,
        %clock,
    );
}

# PostgresHarness::race releases its workers together and waits for all of
# them. These fork one worker and return at once, so the parent can watch it
# wait. The work is handed two callbacks: one tells the parent what it holds,
# the other blocks until the parent lets it go on.
sub _spawn {
    my ($work) = @_;

    pipe my $out_reader,   my $out_writer   or croak 'result pipe failed';
    pipe my $ready_reader, my $ready_writer or croak 'ready pipe failed';
    pipe my $go_reader,    my $go_writer    or croak 'go pipe failed';
    my $pid = fork;
    if ( !defined $pid ) {
        croak "fork failed: $OS_ERROR";
    }
    if ( $pid == 0 ) {
        _close_all( $out_reader, $ready_reader, $go_writer );
        $ready_writer->autoflush(1);
        my $result = eval {
            return $work->(
                sub {
                    my ($note) = @_;
                    print {$ready_writer} encode_json($note), "\n"
                      or croak 'ready write failed';
                    return;
                },
                sub { return scalar readline $go_reader; },
            );
        };
        my $payload =
          $result ? { ok => 1, result => $result } : { error => "$EVAL_ERROR" };
        print {$out_writer} encode_json($payload)
          or croak 'result write failed';
        _close_all( $out_writer, $ready_writer, $go_reader );

        # _exit skips the destructors that would close the parent's handles.
        _exit(0);
    }

    _close_all( $out_writer, $ready_writer, $go_reader );
    $go_writer->autoflush(1);

    return {
        go    => $go_writer,
        out   => $out_reader,
        pid   => $pid,
        ready => $ready_reader,
    };
}

sub _await_ready {
    my ($child) = @_;

    my $line = readline $child->{ready};
    if ( !defined $line ) {
        my $outcome = _collect($child);
        croak 'worker stopped before it was ready: '
          . ( $outcome->{error} // 'no error' );
    }

    return decode_json($line);
}

sub _release {
    my ($child) = @_;

    print { $child->{go} } "go\n" or croak 'go write failed';

    return;
}

sub _collect {
    my ($child) = @_;

    _close_all( delete @{$child}{qw(go ready)} );
    local $INPUT_RECORD_SEPARATOR = undef;
    my $json = readline $child->{out};
    close $child->{out} or croak 'result reader close failed';
    waitpid $child->{pid}, 0;

    return decode_json($json);
}

sub _close_all {
    my (@handles) = @_;

    for my $handle ( grep { defined } @handles ) {
        close $handle or croak "close failed: $OS_ERROR";
    }

    return;
}

sub _await_row_wait {
    my ($holder_pid) = @_;

    for ( 1 .. $BLOCK_POLLS ) {
        my ($waiting) =
          $dbh->selectrow_array( $ROW_WAIT_SQL, undef, $holder_pid );
        return 1 if $waiting;
        $dbh->do( 'SELECT pg_sleep(?)', undef, $BLOCK_POLL_SECONDS );
    }

    return 0;
}

1;
