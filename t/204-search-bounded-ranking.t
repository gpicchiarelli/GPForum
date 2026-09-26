# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Search::Searcher;
use GPForum::Test::FailingSearchResultSet;
use GPForum::Test::SearchPermissionEngine;
use GPForum::Test::SearchRow;
use GPForum::Test::SearchSchema;
use GPForum::Test::SearchTimeoutStorage;

our $VERSION = '0.001';

const my $DEFAULT_CANDIDATES => 1_000;
const my $SMALL_CAP          => 2;
const my $PAGE               => 5;
const my $TIMEOUT_MS         => 1_500;
const my $CONFIGURED_TIMEOUT => 750;
const my $CONFIGURED_CAP     => 300;

# Search is bounded two ways (quality program 8.10). It ranks only the newest
# candidate_limit matches, so a word most documents hold is not scored over
# the whole corpus; and it runs under its own statement_timeout, so whatever
# still runs long is cancelled before it holds a web worker. The plans are
# pinned against PostgreSQL in t/integration/postgres-search-plan.t; this pins
# the query's shape and the transaction the timeout lives in.

my ( $documents, $schema ) = _search_schema( _rows($SMALL_CAP) );
my $searcher = GPForum::Service::Search::Searcher->new(
    permission_engine => GPForum::Test::SearchPermissionEngine->new,
    schema            => $schema,
);

my $ranked = $searcher->search_resultset( undef, 'forum', { limit => $PAGE } );
my $candidates = $ranked->candidate_attrs;
is( $candidates->{rows}, $DEFAULT_CANDIDATES,
    'search ranks at most 1,000 candidates by default' );
is_deeply(
    $candidates->{order_by},
    [ { -desc => 'me.source_created_at' }, { -desc => 'me.entity_id' } ],
    'the candidates are the newest matches, in the new index order'
);
is_deeply( $candidates->{join}, [qw(category space)],
    'the candidates join only what the permission condition reads' );
like( ${ $documents->last_query->{-or}[0] }->[0],
    qr/websearch_to_tsquery/msx, 'the candidates are the matches' );
is_deeply(
    $documents->last_query->{-and}[0],
    { 'me.visibility' => { -in => ['public'] } },
    'and only those the actor may read, before the cap is applied'
);

my $outer = $documents->last_attrs;
is( $outer->{rows}, $PAGE, 'the ranked query returns one page' );
like( ${ $outer->{'+select'}[0] }->[0],
    qr/ts_rank_cd/msx, 'and ranks the candidates as search always has' );
is(
    ${ $outer->{'+select'}[-1] },
    'count(*) OVER ()',
    'every row says how many candidates were ranked'
);
is( $outer->{'+as'}[-1],
    'candidate_count', 'as candidate_count, which is how the cap is detected' );

$searcher->candidate_limit($SMALL_CAP);
is(
    $searcher->search_resultset( undef, 'forum', {} )->candidate_attrs->{rows},
    $SMALL_CAP,
    'the cap is configurable'
);

my $capped = $searcher->ranked_search( undef, 'forum', { limit => $PAGE } );
is( $capped->{ranking_capped},
    1, 'filling every candidate slot marks the ranking capped' );
is( $capped->{candidate_limit},     $SMALL_CAP, 'and says at how many' );
is( scalar @{ $capped->{results} }, $SMALL_CAP, 'with the ranked results' );
ok( !exists $capped->{results}[0]{candidate_count},
    'the count is not a result field' );

$searcher->candidate_limit($DEFAULT_CANDIDATES);
is( $searcher->ranked_search( undef, 'forum', {} )->{ranking_capped},
    0, 'fewer candidates than the cap are not capped' );
is_deeply(
    $searcher->search( undef, 'forum', {} ),
    $searcher->ranked_search( undef, 'forum', {} )->{results},
    'search returns the same results without the note'
);

my ( undef, $empty_schema ) = _search_schema( [] );
my $none = GPForum::Service::Search::Searcher->new(
    permission_engine => GPForum::Test::SearchPermissionEngine->new,
    schema            => $empty_schema,
)->ranked_search( undef, 'forum', {} );
is( $none->{ranking_capped}, 0, 'no match is not a capped ranking' );

# Without a timeout configured nothing changes: no transaction, no setting.
is( $schema->transaction_count,
    0, 'without a search timeout search runs outside a transaction' );
is_deeply( $schema->storage->statements,
    [], 'and leaves statement_timeout alone' );

# Zero is not "no timeout": set_config would switch search's off, not relax it.
$searcher->statement_timeout_ms(0);
$searcher->search( undef, 'forum', {} );
is( $schema->transaction_count,
    0, 'a zero search timeout leaves search under the connection timeout' );

$searcher->statement_timeout_ms($TIMEOUT_MS);
$searcher->search( undef, 'forum', { limit => $PAGE } );
is( $schema->transaction_count, 1, 'a timed search runs in a transaction' );
is_deeply(
    $schema->storage->statements,
    [ [ q{SELECT set_config('statement_timeout', ?, true)}, $TIMEOUT_MS, 1 ] ],
    'which sets its own statement_timeout, local to it, before the query'
);

$searcher->autocomplete( undef, 'wel', {} );
is( $schema->transaction_count, 2, 'autocomplete is timed the same way' );
is( scalar @{ $schema->storage->statements },
    2, 'with its own statement_timeout' );

# The database cancelling the statement is an error like any other: it leaves
# the transaction and reaches the controller, which renders the page degraded.
$documents->failure("canceling statement due to statement timeout\n");
my $opened = $schema->transaction_count;
my $failed = eval { $searcher->search( undef, 'forum', {} ); 1 };
ok( !$failed, 'a cancelled search fails' );
is( $schema->transaction_count, $opened + 1, 'inside its own transaction' );
like(
    $EVAL_ERROR,
    qr/statement [ ] timeout/msx,
    'with the database error, for the controller to degrade on'
);
is( $schema->transaction_depth, 0, 'and its transaction is closed' );

# The application's searcher takes both bounds from the configuration.
{
    local $ENV{GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS} = $CONFIGURED_TIMEOUT;
    local $ENV{GPFORUM_SEARCH_CANDIDATE_LIMIT}      = $CONFIGURED_CAP;

    my $application = Test::Mojo->new('GPForum')->app;
    my $configured  = $application->build_controller->gp_search_service;
    is( $configured->statement_timeout_ms,
        $CONFIGURED_TIMEOUT,
        'the search service runs under GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS' );
    is( $configured->candidate_limit,
        $CONFIGURED_CAP,
        'and ranks GPFORUM_SEARCH_CANDIDATE_LIMIT candidates' );
}

done_testing();

sub _rows {
    my ($count) = @_;

    return [
        map {
            GPForum::Test::SearchRow->new(
                data => {
                    body              => 'A forum post',
                    candidate_count   => $count,
                    entity_id         => "thread-$_",
                    entity_type       => 'thread',
                    source_created_at => '2026-05-23T12:00:00Z',
                    title             => "Welcome $_",
                    title_normalized  => "welcome $_",
                    visibility        => 'public',
                }
            )
        } 1 .. $count
    ];
}

sub _search_schema {
    my ($rows) = @_;

    my $resultset = GPForum::Test::FailingSearchResultSet->new( rows => $rows );
    my $double    = GPForum::Test::SearchSchema->new(
        resultsets => { SearchDocument => $resultset } );
    $double->storage(
        GPForum::Test::SearchTimeoutStorage->new( schema => $double ) );

    return ( $resultset, $double );
}

1;
