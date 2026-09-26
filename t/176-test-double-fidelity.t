# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::AttachmentResultSet;
use GPForum::Test::AttachmentSchema;
use GPForum::Test::ModerationResultSet;
use GPForum::Test::ModerationSchema;
use GPForum::Test::NotificationResultSet;
use GPForum::Test::NotificationSchema;
use GPForum::Test::Query;
use GPForum::Test::Schema;
use GPForum::Infrastructure::UniqueConflict;

const my $SEEDED_AUDIT_ROWS  => 5;
const my $MIDDLE_AUDIT_INDEX => 3;
const my $HIGH_POSITION      => 10;
const my $PAGE_SIZE          => 2;
const my $PAGE_OFFSET        => 1;
const my $NAMED_ACTOR_ROWS   => 3;
const my $ANONYMOUS_ROWS     => 2;
const my $ROWS_UP_TO_THIRD   => 3;
const my $ROWS_AFTER_THIRD   => 2;
const my $ROWS_EXCEPT_FIRST  => 4;
const my $MATCHED_PAIR       => 2;
const my $MATCHED_SINGLE     => 1;

# The fakes used to bind the search attributes and never read them, so a
# query that asked for the newest row got the oldest one and every range
# predicate compared a value against a stringified hash reference. These
# tests pin the behaviour so the doubles cannot silently drift back.

sub audit_schema {
    my $schema    = GPForum::Test::Schema->new;
    my $resultset = $schema->resultset('AuditLog');
    for my $index ( 1 .. $SEEDED_AUDIT_ROWS ) {
        $resultset->create(
            {
                audit_id   => "audit-$index",
                created_at => sprintf( '2026-05-2%dT00:00:00Z', $index ),
                sequence   => $index,
                actor      => $index % 2 ? 'moderator' : undef,
            }
        );
    }

    return $schema;
}

subtest 'search applies order_by, rows and offset' => sub {
    my $schema    = audit_schema();
    my $resultset = $schema->resultset('AuditLog');

    my $newest = $resultset->search(
        {},
        {
            order_by => [ { -desc => 'created_at' }, { -desc => 'audit_id' } ],
            rows     => 1,
        }
    )->single;
    is( $newest->{audit_id}, "audit-$SEEDED_AUDIT_ROWS",
        'descending order_by with rows => 1 returns the newest row' );

    my $oldest =
      $resultset->search( {}, { order_by => { -asc => 'created_at' } } )
      ->single;
    is( $oldest->{audit_id}, 'audit-1', 'a hashref order_by is honoured too' );

    my @page = $resultset->search(
        {},
        {
            order_by => [ { -asc => 'sequence' } ],
            rows     => $PAGE_SIZE,
            offset   => $PAGE_OFFSET,
        }
    )->all;
    is_deeply(
        [ map { $_->{audit_id} } @page ],
        [ 'audit-2', 'audit-3' ],
        'offset is applied before the row limit'
    );

    my $prefixed =
      $resultset->search( {}, { order_by => { -desc => 'me.created_at' } } )
      ->single;
    is( $prefixed->{audit_id}, "audit-$SEEDED_AUDIT_ROWS",
        'a me. prefix is stripped before the row is read' );

    done_testing();
};

subtest 'ordering compares numbers as numbers' => sub {
    my $schema = GPForum::Test::Schema->new;
    my $posts  = $schema->resultset('Post');
    for my $position ( 1, 2, $HIGH_POSITION ) {
        $posts->create(
            {
                post_id   => "post-$position",
                thread_id => 'thread-1',
                position  => $position,
            }
        );
    }

    my $latest = $posts->search(
        { thread_id => 'thread-1' },
        {
            order_by => [ { -desc => 'position' }, { -desc => 'post_id' } ],
            rows     => 1,
        }
    )->single;
    is( $latest->{position}, $HIGH_POSITION,
        'numeric columns sort numerically, not as text' );

    done_testing();
};

subtest 'search applies comparison operators' => sub {
    my $schema    = audit_schema();
    my $resultset = $schema->resultset('AuditLog');

    is(
        $resultset->search(
            { created_at => { q{<=} => '2026-05-23T00:00:00Z' } }
        )->count,
        $ROWS_UP_TO_THIRD,
        'a <= range predicate filters instead of always matching'
    );
    is(
        $resultset->search( { sequence => { q{>} => $MIDDLE_AUDIT_INDEX } } )
          ->count,
        $ROWS_AFTER_THIRD,
        'a > predicate compares numerically'
    );
    is(
        $resultset->search( { audit_id => { -not_in => ['audit-1'] } } )->count,
        $ROWS_EXCEPT_FIRST,
        '-not_in excludes the listed values'
    );
    is( $resultset->search( { audit_id => { -like => 'audit-%' } } )->count,
        $SEEDED_AUDIT_ROWS, '-like expands the SQL wildcard' );
    is( $resultset->search( { actor => { q{!=} => undef } } )->count,
        $NAMED_ACTOR_ROWS, '!= undef reads as IS NOT NULL' );
    is( $resultset->search( { actor => undef } )->count,
        $ANONYMOUS_ROWS, 'undef reads as IS NULL' );

    done_testing();
};

subtest 'search applies boolean clauses' => sub {
    my $schema    = audit_schema();
    my $resultset = $schema->resultset('AuditLog');

    is(
        $resultset->search(
            { -or => [ { audit_id => 'audit-1' }, { audit_id => 'audit-5' } ] }
        )->count,
        $MATCHED_PAIR,
        '-or matches either clause'
    );
    is(
        $resultset->search(
            { -and => [ { audit_id => 'audit-1' }, { sequence => 1 } ] }
        )->count,
        $MATCHED_SINGLE,
        '-and requires every clause'
    );
    is(
        $resultset->search(
            [ { audit_id => 'audit-1' }, { audit_id => 'audit-5' } ]
        )->count,
        $MATCHED_PAIR,
        'a top-level arrayref is an OR of clauses'
    );

    done_testing();
};

subtest 'search records a requested row lock' => sub {
    my $schema    = audit_schema();
    my $resultset = $schema->resultset('AuditLog');

    is( $schema->row_locks, 0, 'no row lock is recorded up front' );
    $resultset->search( {}, { for => 'update' } );
    is( $schema->row_locks, 1, 'for => update is recorded on the schema' );
    $resultset->search( {}, { rows => 1 } );
    is( $schema->row_locks, 1, 'an unlocked search does not count' );

    done_testing();
};

subtest 'an unsupported operator is refused, not ignored' => sub {
    my $schema = audit_schema();

    my $failed = eval {
        $schema->resultset('AuditLog')
          ->search( { audit_id => { -ilike => 'AUDIT-%' } } );
        1;
    };
    ok( !$failed, 'an unimplemented operator croaks' );
    like(
        $@,
        qr/unsupported [ ] test [ ] query [ ] operator/msx,
        'the failure names the operator'
    );

    done_testing();
};

subtest 'a failed transaction leaves no rows behind' => sub {
    my $schema    = audit_schema();
    my $resultset = $schema->resultset('AuditLog');

    my $survived = eval {
        $schema->txn_do(
            sub {
                $resultset->create(
                    { audit_id => 'audit-6', created_at => 'z' } );
                $resultset->create(
                    { audit_id => 'audit-7', created_at => 'z' } );
                die "write failed\n";
            }
        );
        1;
    };
    ok( !$survived, 'the transaction rethrows the failure' );
    is( scalar @{ $schema->audit_logs },
        $SEEDED_AUDIT_ROWS, 'the storage rows are rolled back' );
    is( scalar @{ $schema->created_for('AuditLog') },
        $SEEDED_AUDIT_ROWS, 'the created log is rolled back as well' );

    done_testing();
};

subtest 'a committed transaction keeps its rows' => sub {
    my $schema    = audit_schema();
    my $resultset = $schema->resultset('AuditLog');

    my $result = $schema->txn_do(
        sub {
            $resultset->create( { audit_id => 'audit-6', created_at => 'z' } );
            return 'committed';
        }
    );
    is( $result, 'committed', 'the transaction returns the body result' );
    is(
        scalar @{ $schema->audit_logs },
        $SEEDED_AUDIT_ROWS + 1,
        'the inserted row survives'
    );

    done_testing();
};

subtest 'resultset-backed schemas roll back too' => sub {
    my %case = (
        attachment => {
            resultset => GPForum::Test::AttachmentResultSet->new,
            row       => { attachment_id => 'attachment-1' },
            schema    => 'GPForum::Test::AttachmentSchema',
        },
        moderation => {
            resultset => GPForum::Test::ModerationResultSet->new,
            row       => { report_id => 'report-1' },
            schema    => 'GPForum::Test::ModerationSchema',
        },
        notification => {
            resultset => GPForum::Test::NotificationResultSet->new,
            row       => { subscription_id => 'subscription-1' },
            schema    => 'GPForum::Test::NotificationSchema',
        },
    );

    for my $name ( sort keys %case ) {
        my $resultset = $case{$name}{resultset};
        my $schema =
          $case{$name}{schema}->new( resultsets => { Thing => $resultset } );
        my $survived = eval {
            $schema->txn_do(
                sub {
                    $resultset->create( $case{$name}{row} );
                    die "write failed\n";
                }
            );
            1;
        };
        ok( !$survived, "$name transaction rethrows the failure" );
        is( scalar @{ $resultset->created },
            0, "$name transaction leaves no created rows behind" );
    }

    done_testing();
};

# PostgreSQL refuses every statement after an error inside a transaction until
# the caller rolls back, to a savepoint or entirely. The doubles used to answer
# queries regardless, so a recovery path that could never run against a real
# database looked correct here. A broken conflict recovery lived in
# twenty-eight stores behind exactly that gap; see docs/QUALITY_PROGRAM.md.
subtest 'aborted transaction semantics' => sub {
    my $schema = GPForum::Test::Schema->new;

    $schema->txn_do(
        sub {
            $schema->resultset('User')->create(
                {
                    id       => 'fidelity-user-1',
                    username => 'fidelity1',
                    email    => 'fidelity1@example.test',
                }
            );

            my $conflicted = eval {
                $schema->resultset('User')->create(
                    {
                        id       => 'fidelity-user-1',
                        username => 'fidelity2',
                        email    => 'fidelity2@example.test',
                    }
                );
                1;
            };
            ok( !$conflicted, 'a duplicate primary key raises' );
            ok( $schema->transaction_aborted,
                'the conflict marks the transaction aborted' );

            my $read = eval {
                $schema->resultset('User')->find( { id => 'fidelity-user-1' } );
            };
            ok( !$read, 'a read after the conflict is refused' );
            like(
                "$EVAL_ERROR",
                qr/current [ ] transaction [ ] is [ ] aborted/msx,
                'the refusal reports SQLSTATE 25P02 the way PostgreSQL does'
            );

            return 1;
        }
    );

    ok( !$schema->transaction_aborted,
        'leaving the transaction clears the aborted state' );

    done_testing();
};

# The savepoint surface is what makes conflict recovery possible at all, so the
# double has to provide it or UniqueConflict->attempt silently degrades to a
# plain eval and the tier stops testing the real thing.
subtest 'savepoint recovery inside a transaction' => sub {
    my $schema = GPForum::Test::Schema->new;
    my $rows   = [];

    $schema->txn_do(
        sub {
            my $users = $schema->resultset('User');
            $users->create(
                {
                    id       => 'savepoint-user-1',
                    username => 'savepoint1',
                    email    => 'savepoint1@example.test',
                }
            );

            my ( $created, $error ) =
              GPForum::Infrastructure::UniqueConflict->attempt(
                $schema,
                sub {
                    return $users->create(
                        {
                            id       => 'savepoint-user-1',
                            username => 'savepoint2',
                            email    => 'savepoint2@example.test',
                        }
                    );
                }
              );
            ok( !$created, 'the duplicate insert fails inside the savepoint' );
            ok(
                GPForum::Infrastructure::UniqueConflict->is_conflict($error),
                'the failure is classified as a unique conflict'
            );
            ok( !$schema->transaction_aborted,
                'rolling back to the savepoint makes the transaction usable' );

            $rows = [ $users->find( { id => 'savepoint-user-1' } ) ];
            ok( $rows->[0], 'the recovery read succeeds' );

            is( scalar @{ $schema->storage->savepoints },
                0, 'attempt leaves no savepoint behind' );

            return 1;
        }
    );

    is( scalar @{ $schema->created_for('User') },
        1, 'only the first insert survives' );

    done_testing();
};

done_testing();
