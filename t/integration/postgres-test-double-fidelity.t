# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::BareStorage;
use GPForum::Test::CommunityResultSet;
use GPForum::Test::Dbh;
use GPForum::Test::EngineeringCorrectness::Schema;
use GPForum::Test::ForumReadResultSet;
use GPForum::Test::ModerationResultSet;
use GPForum::Test::NotificationResultSet;
use GPForum::Test::OutboxCreateResultSet;
use GPForum::Test::PgDatabase;
use GPForum::Test::Row;
use GPForum::Test::SearchResult;

our $VERSION = '0.001';

# The shared doubles side by side with DBIx::Class on PostgreSQL, for the
# behaviours a review found them to diverge on: what a miss returns in list
# context, what search returns in list context, the savepoint calls, the
# column aggregate's methods and get_inflated_column on a name that is not a
# column. Each divergence let a caller pass in the unit suite and fail, or
# misbehave, on PostgreSQL.
const my $BUDGET  => 'GPForum::Schema::Result::EndpointQueryBudget';
const my $MISSING => 'no-such-endpoint';

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the double fidelity test';
}

my $database = GPForum::Test::PgDatabase->fresh;
my $schema   = $database->schema;
my $budgets  = $schema->resultset('EndpointQueryBudget');
for my $queries ( 1, 2 ) {
    $budgets->create(
        {
            created_at    => \'now()',
            endpoint_name => "endpoint-$queries",
            max_queries   => $queries,
        }
    );
}

# Migrating also installs the application's query budget catalog. Keep this
# comparison on the two fixture rows, independent of the catalog's size.
$budgets = $budgets->search_rs(
    { endpoint_name => { -in => [qw(endpoint-1 endpoint-2)] } } );

subtest 'a find or single that misses is one undef in list context' => sub {
    my @real = $budgets->find($MISSING);
    is_deeply( \@real, [undef], 'DBIx::Class find gives one undef' );
    my @single = $budgets->search_rs( { endpoint_name => $MISSING } )->single;
    is_deeply( \@single, [undef], 'and so does single' );

    my %misses = (
        'CommunityResultSet find' => sub {
            GPForum::Test::CommunityResultSet->new( find_misses => 1 )
              ->find($MISSING);
        },
        'ModerationResultSet find' => sub {
            GPForum::Test::ModerationResultSet->new( find_misses => 1 )
              ->find($MISSING);
        },
        'NotificationResultSet find' => sub {
            GPForum::Test::NotificationResultSet->new( find_misses => 1 )
              ->find($MISSING);
        },
        'OutboxCreateResultSet find' => sub {
            GPForum::Test::OutboxCreateResultSet->new( find_misses => 1 )
              ->find( {} );
        },
        'ForumReadResultSet find by value' => sub {
            GPForum::Test::ForumReadResultSet->new->find($MISSING);
        },
        'ForumReadResultSet find by condition' => sub {
            GPForum::Test::ForumReadResultSet->new->find(
                { post_id => $MISSING } );
        },
        'engineering find' => sub {
            _engineering_reports()->find($MISSING);
        },
        'engineering find by condition' => sub {
            _engineering_reports()->find( { report_id => $MISSING } );
        },
        'engineering single' => sub {
            _engineering_reports()->search( { report_id => $MISSING } )->single;
        },
    );
    for my $name ( sort keys %misses ) {
        my @double = $misses{$name}->();
        is_deeply( \@double, \@real, "the double's $name gives the same" );
    }
};

subtest 'search in list context is the rows' => sub {
    my @real = $budgets->search( {}, { order_by => 'endpoint_name' } );
    is( scalar @real, 2, 'DBIx::Class gives the rows, not a resultset' );

    my $search =
      GPForum::Test::SearchResult->new( rows => [ { id => 1 }, { id => 2 } ] );
    my @double = $search->search( {} );
    is_deeply(
        \@double,
        [ { id => 1 }, { id => 2 } ],
        'and so does the search double'
    );
    isa_ok( scalar $search->search( {} ),
        'GPForum::Test::SearchResult',
        'which is a resultset in scalar context' );
};

subtest 'savepoints behave as DBIx::Class makes them behave' => sub {
    my $storage = $schema->storage;
    my $double =
      GPForum::Test::BareStorage->new( dbh => GPForum::Test::Dbh->new );

    my $real_outside = _error( sub { $storage->svp_begin } );
    like(
        $real_outside,
        qr/You [ ] can't [ ] use [ ] savepoints [ ] outside/msx,
        'DBIx::Class refuses a savepoint outside a transaction'
    );
    like(
        _error( sub { $double->svp_begin } ),
        qr/\A You [ ] can't [ ] use [ ] savepoints [ ] outside/msx,
        'and so does the double'
    );

    my ( @real, @double );
    $schema->txn_do(
        sub {
            push @real, $storage->svp_begin;
            $storage->svp_begin;
            push @real, [ @{ $storage->savepoints } ];
            $storage->svp_release;
            push @real, [ @{ $storage->savepoints } ];
            $storage->svp_rollback;
            push @real, [ @{ $storage->savepoints } ];
            $storage->svp_release;
        }
    );
    $double->transaction_depth(1);
    push @double, $double->svp_begin;
    $double->svp_begin;
    push @double, [ @{ $double->savepoints } ];
    $double->svp_release;
    push @double, [ @{ $double->savepoints } ];
    $double->svp_rollback;
    push @double, [ @{ $double->savepoints } ];

    is( $real[0], 1, 'svp_begin returns 1 on PostgreSQL, not the name' );
    is_deeply( \@double, \@real,
            'the double returns the same, mints the same names and releases '
          . 'and rolls back the most recent when none is named' );
};

subtest 'a column aggregate has no count method' => sub {
    my $real = $budgets->get_column('max_queries');
    my $double =
      GPForum::Test::SearchResult->new(
        rows => [ { max_queries => 1 }, { max_queries => 2 } ] )
      ->get_column('max_queries');

    ok( !$real->can('count'),   'DBIx::Class::ResultSetColumn has none' );
    ok( !$double->can('count'), 'nor has the double' );
    is(
        $double->func('COUNT'),
        $real->func('COUNT'),
        'both count through func'
    );
};

subtest 'get_inflated_column on a name that is not a column' => sub {
    my $real   = $budgets->find('endpoint-1');
    my $double = GPForum::Test::Row->new(
        data         => { endpoint_name => 'endpoint-1' },
        result_class => $BUDGET
    );
    my $refused = qr/No [ ] such [ ] column [ ] no_such/msx;

    like( _error( sub { $real->get_inflated_column('no_such') } ),
        $refused, 'DBIx::Class refuses it as no such column' );
    like( _error( sub { $double->get_inflated_column('no_such') } ),
        $refused, 'and so does the double' );
    like(
        _error( sub { $double->get_inflated_column('max_queries') } ),
        qr/\A max_queries [ ] is [ ] not [ ] an [ ] inflated [ ] column/msx,
        'while a plain column is not an inflated one, on both'
    );
};

done_testing();

# The engineering-correctness double's reports, a fresh schema each time.
sub _engineering_reports {
    return GPForum::Test::EngineeringCorrectness::Schema->new->resultset(
        'Report');
}

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
