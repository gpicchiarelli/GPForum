# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Search::PermissionEngine;
use GPForum::Service::Search::Searcher;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $THRESHOLD => '0.18';
const my $LIMIT     => 20;

# Every search used to be a sequential scan of search_documents: the tsquery
# read its configuration from a column of the same row, the fuzzy arm was
# similarity(...) >= ? rather than a pg_trgm operator, and an OR needs every
# arm indexable before the planner will build a BitmapOr. The unit tier pins
# the SQL shape; only a database can say whether an index is usable. With
# sequential scans disabled, a Seq Scan that survives means no index could
# serve the query at all -- which is what the old query produced, for anonymous
# callers and members alike.
#
# This asks the application for its query rather than transcribing it:
# search_resultset returns what search() executes, rendered with as_query.

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the search plan test';
}

local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;

my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};

my $prepared = GPForum::Test::PostgresHarness::prepare_database();
is( $prepared->{migrate}, 0, 'migrations apply' );
is( $prepared->{seed},    0, 'the small seed profile loads' );

my $schema = GPForum::Test::PostgresHarness::connect_schema();
my $dbh    = $schema->storage->dbh;

# The fuzzy arm's threshold is a session setting now, not a bind. If the
# connection did not carry it, pg_trgm's default of 0.3 would silently drop
# every match between 0.18 and 0.3.
is(
    $dbh->selectrow_array(
        q{SELECT current_setting('pg_trgm.similarity_threshold', true)}),
    $THRESHOLD,
    'the connection carries the search similarity threshold'
);

my $member = $dbh->selectrow_array('SELECT id FROM users ORDER BY id LIMIT 1');
my $searcher = GPForum::Service::Search::Searcher->new(
    schema            => $schema,
    permission_engine =>
      GPForum::Service::Search::PermissionEngine->new( schema => $schema ),
);

for my $viewer ( [ anonymous => undef ], [ member => { user_id => $member } ] )
{
    my ( $label, $actor ) = @{$viewer};

    my $results =
      $searcher->search( $actor, 'performance', { limit => $LIMIT } );
    ok( scalar @{$results}, "$label: a full-text search finds documents" );

    my $plan = GPForum::Test::PostgresHarness::plan_without_seqscan(
        $dbh,
        $searcher->search_resultset(
            $actor, 'performance', { limit => $LIMIT }
        )
    );
    unlike(
        $plan,
        qr/Seq \s Scan \s on \s search_documents/msx,
        "$label: an index can serve the search"
    ) or diag $plan;
    like(
        $plan,
        qr/idx_search_documents_vector/msx,
        "$label: the full-text arm uses the GIN index"
    );
    like(
        $plan,
        qr/idx_search_documents_title_trgm/msx,
        "$label: the fuzzy arm uses the trigram index"
    );

    # Best similarity to the seeded titles is about 0.29: above the configured
    # 0.18, below pg_trgm's default 0.3.
    my $fuzzy = $searcher->search( $actor, 'perf thrd', { limit => $LIMIT } );
    ok( scalar @{$fuzzy},
        "$label: a match between 0.18 and 0.3 similarity is still found" );
}

GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

1;
