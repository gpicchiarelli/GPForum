# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::ModerationResultSet;
use GPForum::Test::ModerationSchema;
use GPForum::Test::NotificationRow;
use GPForum::Test::RowState;
use GPForum::Test::Transaction;
use GPForum::Test::TransactionalSchema;
use GPForum::X::Conflict;

our $VERSION = '0.001';

const my $SEEDED   => 3;
const my $INSERTED => 4;

# A transaction body that dies leaves the double as it found it: the rows a
# row set held, and what each row held. The doubles used to copy the row sets
# only, so an UPDATE the failed body made survived the rollback, and a test
# could not tell a rollback from a commit.

subtest 'capture and restore put membership and columns back' => sub {
    my $kept      = { id => 1, status => 'open' };
    my $replaced  = GPForum::Test::ModerationRow->new( data => { id => 2 } );
    my $inplace   = GPForum::Test::NotificationRow->new( data => { id => 3 } );
    my @rows      = ( $kept, $replaced, $inplace );
    my %by_id     = ( 1 => $kept );
    my $held_data = $replaced->data;

    my $state = GPForum::Test::RowState::capture( \@rows, \%by_id );
    $kept->{status} = 'resolved';
    $replaced->update( { status => 'hidden' } );
    $inplace->update( { status => 'read' } );
    push @rows, { id => $INSERTED };
    $by_id{$INSERTED} = $rows[-1];
    GPForum::Test::RowState::restore($state);

    is( scalar @rows, $SEEDED, 'an inserted row is gone' );
    ok( !exists $by_id{$INSERTED}, 'from every container' );
    is( $kept->{status}, 'open', 'a hash row has its column back' );
    is( $replaced->data, $held_data,
        'a row whose update replaced its hash gets the old one back' );
    ok( !exists $replaced->data->{status}, 'with the old columns' );
    ok( !exists $inplace->data->{status},
        'a row updated in place has its columns back' );
};

subtest 'a transactional schema rolls a row update back' => sub {
    my $row    = GPForum::Test::NotificationRow->new( data => { id => 1 } );
    my $schema = GPForum::Test::TransactionalSchema->new;
    my $things = $schema->created_for('Thing');
    push @{$things}, $row;

    my $error = _failure(
        sub {
            $schema->txn_do(
                sub {
                    $row->update( { status => 'read' } );
                    push @{$things}, { id => 2 };
                    die "insert failed\n";
                }
            );
        }
    );

    like( $error, qr/\A insert [ ] failed/msx, 'the failure comes back' );
    is( scalar @{$things}, 1, 'the inserted row is gone' );
    ok( !exists $row->data->{status}, 'and the update is undone' );

    my $conflict = GPForum::X::Conflict->new( message => 'duplicate key' );
    is(
        _failure(
            sub {
                $schema->txn_do( sub { $conflict->rethrow } );
            }
        ),
        $conflict,
        'an exception object comes back unchanged, as from DBIx::Class'
    );

    $schema->txn_do( sub { $row->update( { status => 'read' } ) } );
    is( $row->get_column('status'), 'read', 'a body that returns commits' );
};

subtest 'a savepoint rollback puts a row column back' => sub {
    my $reports = GPForum::Test::ModerationResultSet->new;
    my $schema =
      GPForum::Test::ModerationSchema->new(
        resultsets => { Report => $reports } );
    my $report =
      $reports->create( { report_id => 'report-1', status => 'open' } );

    $schema->txn_do(
        sub {
            my $storage = $schema->storage;
            $storage->svp_begin;
            my $savepoint = $storage->savepoints->[-1];
            $report->update( { status => 'resolved' } );
            $storage->svp_rollback($savepoint);
            $storage->svp_release($savepoint);
        }
    );

    is( $report->get_column('status'),
        'open', 'the update after the savepoint is undone' );
};

subtest 'GPForum::Test::Transaction::run undoes updates too' => sub {
    my $reports = GPForum::Test::ModerationResultSet->new;
    my $report =
      $reports->create( { report_id => 'report-1', status => 'open' } );

    my $error = _failure(
        sub {
            GPForum::Test::Transaction::run(
                [$reports],
                sub {
                    $report->update( { status => 'resolved' } );
                    $reports->create( { report_id => 'report-2' } );
                    die "audit failed\n";
                }
            );
        }
    );

    like( $error, qr/\A audit [ ] failed/msx, 'the failure comes back' );
    is( $report->get_column('status'),         'open', 'the update is undone' );
    is( scalar @{ $reports->created_objects }, 1,      'the insert is undone' );
};

done_testing();

sub _failure ($code) {
    my $error;
    try {
        $code->();
    }
    catch ($caught) {
        $error = $caught;
    };

    return $error;
}

1;
