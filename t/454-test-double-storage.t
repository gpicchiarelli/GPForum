# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use DBIx::Class::Storage::DBI;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::Storage;
use GPForum::Test::AuditChainSchema;
use GPForum::Test::AuditChainStorage;
use GPForum::Test::BareStorage;
use GPForum::Test::DbQueryStatsStorage;
use GPForum::Test::Dbh;
use GPForum::Test::EngineeringCorrectness::Schema;
use GPForum::Test::ForumReadSchema;
use GPForum::Test::Id;
use GPForum::Test::MigrationStorage;
use GPForum::Test::QueryBudgetSchema;
use GPForum::Test::RateLimitStorage;
use GPForum::Test::RealtimeBusStorage;
use GPForum::Test::Storage;
use GPForum::Test::TransactionalSchema;

our $VERSION = '0.001';

# Every storage double answers what DBIx::Class's storage answers and lib/
# asks for, and a double without a database says so the way a schema that
# cannot connect does: dbh and dbh_of are undef, and dbh_do and the savepoint
# methods fail as DBIx::Class fails them.
const my @STORAGE_METHODS =>
  qw(dbh dbh_do debug debugobj svp_begin svp_release svp_rollback
  transaction_depth);
const my $OUTSIDE_TRANSACTION =>
qr/\A You [ ] can't [ ] use [ ] savepoints [ ] outside [ ] a [ ] transaction/msx;
const my @STORAGE_DOUBLES => qw(
  GPForum::Test::AuditChainStorage
  GPForum::Test::BareStorage
  GPForum::Test::DbQueryStatsStorage
  GPForum::Test::MigrationStorage
  GPForum::Test::RateLimitStorage
  GPForum::Test::RealtimeBusStorage
  GPForum::Test::Storage
);

subtest q{DBIx::Class's storage answers every one of them} => sub {
    my @missing =
      grep { !DBIx::Class::Storage::DBI->can($_) } @STORAGE_METHODS;
    is_deeply( \@missing, [],
        'so a double asked for them answers as it would' );
    ok( !DBIx::Class::Storage::DBI->can('txn_depth'),
        'and it has no txn_depth: its depth is transaction_depth' );
};

subtest 'every shared storage double answers the storage methods' => sub {
    for my $class (@STORAGE_DOUBLES) {
        my @missing = grep { !$class->can($_) } @STORAGE_METHODS;
        is_deeply( \@missing, [], "$class answers them all" );
    }
};

subtest 'no storage double answers a depth DBIx::Class does not' => sub {
    my @answering = grep { $_->can('txn_depth') } @STORAGE_DOUBLES;

  TODO: {
        local $TODO = 'Storage and AuditChainStorage keep txn_depth until '
          . 'EventRecorder, PostStoreLockStorage, t/159 and t/316 stop asking';
        is_deeply( \@answering, [],
            'a probe for txn_depth is false on every double, as on PostgreSQL'
        );
    }
};

# EventRecorder::_needs_transaction asks the storage for txn_depth, which
# DBIx::Class's storage does not have: on PostgreSQL an autocommit audit
# append takes pg_advisory_xact_lock outside any transaction, and the lock is
# gone at statement end. A double that answered txn_depth hid it.
subtest q{an autocommit audit append on DBIx::Class's storage} => sub {
    my $schema = GPForum::Test::AuditChainSchema->new;
    $schema->storage( DBIx::Class::Storage::DBI->new($schema) );
    GPForum::Infrastructure::EventRecorder->new(
        id_service => GPForum::Test::Id->new,
        schema     => $schema,
    )->record_audit(
        action         => 'thread.created',
        actor_id       => 'user-1',
        correlation_id => 'correlation-1',
        target_id      => 'thread-1',
        target_type    => 'thread',
    );

    is( scalar @{ $schema->created_for('AuditLog') },
        1, 'writes the audit row' );
  TODO: {
        local $TODO = 'EventRecorder::_needs_transaction asks for txn_depth';
        is( $schema->transaction_count, 1, 'inside a transaction of its own' );
    }
};

subtest 'every shared schema double has a storage' => sub {
    for my $schema (
        GPForum::Test::EngineeringCorrectness::Schema->new,
        GPForum::Test::ForumReadSchema->new,
        GPForum::Test::QueryBudgetSchema->new,
      )
    {
        my $storage = GPForum::Infrastructure::Storage->storage_of($schema);
        ok( $storage, ref($schema) . ' has one' );
        is( GPForum::Infrastructure::Storage->dbh_of($schema),
            undef, 'with no database behind it' );
    }
};

subtest 'a storage without a database fails as DBIx::Class does' => sub {
    my $storage = GPForum::Test::BareStorage->new;

    is( $storage->dbh, undef, 'it has no handle' );
    for my $call (
        [
            dbh_do => sub {
                $storage->dbh_do( sub { return 1 } );
            }
        ],
      )
    {
        my ( $name, $code ) = @{$call};
        like(
            _error($code),
            qr/\A DBI [ ] Connection [ ] failed/msx,
            "$name fails with DBIx::Class's connection failure"
        );
    }
    like( _error( sub { $storage->svp_begin } ),
        $OUTSIDE_TRANSACTION,
        'a savepoint is refused first for being outside a transaction' );
};

subtest 'dbh_do runs the code with the storage and the handle' => sub {
    my $dbh     = GPForum::Test::Dbh->new;
    my $storage = GPForum::Test::BareStorage->new( dbh => $dbh );

    my @seen = $storage->dbh_do(
        sub ( $given, $handle, @arguments ) {
            return ( $given, $handle, @arguments );
        },
        'argument'
    );

    is( $seen[0], $storage,   'the storage first' );
    is( $seen[1], $dbh,       'then the handle' );
    is( $seen[2], 'argument', 'then the arguments' );
};

subtest 'the savepoint stack keeps DBIx::Class names and rules' => sub {
    my $storage =
      GPForum::Test::BareStorage->new( dbh => GPForum::Test::Dbh->new );

    like(
        _error( sub { $storage->svp_begin } ),
        $OUTSIDE_TRANSACTION,
'outside a transaction a savepoint is refused, as DBIx::Class refuses it'
    );
    $storage->transaction_depth(1);

    is( $storage->svp_begin, 1,
        'svp_begin returns what DBD::Pg returns, not the name' );
    $storage->svp_begin;
    my ( $outer, $inner ) = @{ $storage->savepoints };
    is_deeply(
        [ $outer, $inner ],
        [qw(savepoint_0 savepoint_1)],
        'names are minted as DBIx::Class mints them, on savepoints'
    );
    $storage->svp_rollback($outer);
    is_deeply( $storage->savepoints, [$outer],
        'a rollback keeps the named savepoint and drops the later ones' );
    $storage->svp_release($outer);
    is_deeply( $storage->savepoints, [], 'a release drops it' );
    like(
        _error( sub { $storage->svp_release } ),
        qr/\A No [ ] savepoints [ ] to [ ] release/msx,
        'a nameless release with none left is refused'
    );
    $storage->svp_begin;
    $storage->svp_begin;
    $storage->svp_release;
    is_deeply( $storage->savepoints, [$outer],
        'a nameless release drops the most recent, as DBIx::Class does' );
    $storage->svp_rollback;
    is_deeply( $storage->savepoints, [$outer],
        'and a nameless rollback keeps it' );
    $storage->svp_release($outer);
    like(
        _error( sub { $storage->svp_release($outer) } ),
        qr/\A Savepoint [ ] 'savepoint_0' [ ] does [ ] not [ ] exist/msx,
        'a savepoint not on the stack is refused'
    );
};

subtest 'the schema storage snapshots rows on top of the stack' => sub {
    my $schema  = GPForum::Test::TransactionalSchema->new;
    my $storage = $schema->storage;

    $schema->txn_do(
        sub {
            ok( !$storage->dbh->{AutoCommit}, 'inside a transaction' );
            $storage->svp_begin;
            my $name = $storage->savepoints->[-1];
            is( $name, 'savepoint_0', 'it mints the name through the base' );
            is( scalar @{ $storage->snapshots }, 1,
                'and snapshots the schema' );
            $storage->svp_release($name);
        }
    );
    ok( $storage->dbh->{AutoCommit}, 'and autocommit outside it' );
};

subtest 'the audit chain storage reports AutoCommit as a DBI handle does' =>
  sub {
    my $schema = GPForum::Test::AuditChainSchema->new;
    my $inside;

    $schema->txn_do( sub { $inside = $schema->storage->dbh->{AutoCommit} } );

    is( $inside,                             0, 'off inside a transaction' );
    is( $schema->storage->dbh->{AutoCommit}, 1, 'on outside one' );
  };

subtest 'the engineering schema reports its transaction depth' => sub {
    my $schema = GPForum::Test::EngineeringCorrectness::Schema->new;
    my $inside;

    $schema->txn_do( sub { $inside = $schema->storage->transaction_depth } );

    is( $inside, 1, 'inside txn_do the storage is one deep' );
    is( $schema->storage->transaction_depth, 0, 'and back at zero after it' );
    _error(
        sub {
            $schema->txn_do( sub { croak 'failed' } );
        }
    );
    is( $schema->storage->transaction_depth, 0, 'a failed body leaves it too' );
};

done_testing();

sub _error ($code) {
    my $error = q{};
    try {
        $code->();
    }
    catch ($caught) {
        $error = "$caught";
    };

    return $error;
}

1;
