# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use DBI;
use DBIx::Class::ResultSet;
use DBIx::Class::Row;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::OutboxBenchmarkDbh;
use GPForum::Test::PartitionDbh;
use GPForum::Test::PurgeResultSet;
use GPForum::Test::PurgeRow;
use GPForum::Test::ReadinessSchema;

our $VERSION = '0.001';

# The handle, row and resultset doubles answer under the names DBI and
# DBIx::Class give their methods, and not under names of their own: lib/
# asked ->can('execute_statement'), ->can('select_column'), ->can('remove')
# and ->can('items') because doubles had those and the real classes do not.
const my $ACK_SQL => 'UPDATE outbox_messages SET status = ?';

subtest 'the real classes have the names and lack the others' => sub {
    for my $method (qw(do selectcol_arrayref selectall_arrayref state)) {
        ok( DBI::db->can($method), "DBI's handle has $method" );
    }
    for my $method (qw(execute_statement select_column driver_name)) {
        ok( !DBI::db->can($method), "DBI's handle has no $method" );
    }
    ok( DBIx::Class::Row->can('delete'),       'a row has delete' );
    ok( !DBIx::Class::Row->can('remove'),      'and no remove' );
    ok( DBIx::Class::ResultSet->can('next'),   'a resultset has next' );
    ok( !DBIx::Class::ResultSet->can('items'), 'and no items' );
};

subtest 'the outbox benchmark handle is DBI-shaped' => sub {
    my $dbh = GPForum::Test::OutboxBenchmarkDbh->new;

    for my $method (qw(do selectcol_arrayref selectall_arrayref)) {
        ok( $dbh->can($method), "it has $method" );
    }
    for my $method (qw(execute_statement select_column driver_name)) {
        ok( !$dbh->can($method), "it has no $method" );
    }
    is( $dbh->{Driver}{Name}, 'Pg', 'its driver is where DBI keeps it' );

    is( $dbh->do( $ACK_SQL, undef, 'sent' ), 1, 'do runs a statement' );
    is_deeply(
        $dbh->selectcol_arrayref(
            $ACK_SQL, undef, 'sent', 'now', 'id-1', 'worker', 'claimed'
        ),
        ['id-1'],
        'selectcol_arrayref returns the acknowledged ids'
    );
    is( $dbh->outcome_writes, 2, 'each acknowledging statement is counted' );
    is_deeply( $dbh->do_sql, [ $ACK_SQL, $ACK_SQL ], 'and recorded' );
};

subtest 'the partition handle answers DBI do and state' => sub {
    my $dbh = GPForum::Test::PartitionDbh->new;

    ok( $dbh->can('do'),    'it has do' );
    ok( $dbh->can('state'), 'and state' );
    is( $dbh->state, undef, 'which is unset until a test scripts a failure' );

    $dbh->begin_work;
    is( $dbh->do('CREATE TABLE events_2026_10 (LIKE events)'),
        1, 'do creates the partition' );
    $dbh->commit;
    ok( $dbh->relations->{events_2026_10}, 'which exists once committed' );
    is( $dbh->execute_statement('CREATE TABLE events_2026_11 (LIKE events)'),
        1, 'execute_statement is the same do' );
    is( scalar @{ $dbh->statements }, 2, 'both statements are recorded' );
};

subtest 'purge rows and resultsets answer as DBIx::Class does' => sub {
    my $row = GPForum::Test::PurgeRow->new( values => { id => 1 } );
    ok( !$row->can('remove'), 'a purge row has no remove' );
    $row->delete;
    ok( $row->deleted, 'its delete is the purge' );

    my $search = GPForum::Test::PurgeResultSet->new( rows => [$row] );
    ok( !$search->can('items'), 'a purge resultset has no items' );
    is_deeply( [ $search->all ], [$row], 'all lists its rows' );
};

subtest 'the readiness schema reads an empty table as DBIx::Class does' => sub {
    my $probe = GPForum::Test::ReadinessSchema->new->resultset('User')
      ->search_rs( {}, { rows => 1 } );

    is( $probe->next,   undef, 'next is undef' );
    is( $probe->single, undef, 'single is undef' );
    my @single = $probe->single;
    is_deeply( \@single, [undef], 'and single is one undef in list context' );
};

done_testing();

1;
