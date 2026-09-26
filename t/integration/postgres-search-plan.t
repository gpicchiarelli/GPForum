# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(decode_json);
use Test::More;
use Time::HiRes qw(time);

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::Viewer;
use GPForum::Service::Search::PermissionEngine;
use GPForum::Service::Search::Searcher;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $THRESHOLD       => '0.18';
const my $LIMIT           => 20;
const my $CORPUS          => 20_000;
const my $CANDIDATES      => 1_000;
const my $RARE_EVERY      => 7_000;
const my $RARE_MATCHES    => 3;
const my $TIMEOUT_MS      => 200;
const my $LOCK_TIMEOUT_MS => 3_000;
const my $MILLISECONDS    => 1_000;
const my $SESSION_TIMEOUT => '15s';
const my $ANALYZE_THRESHOLDS_SQL => join q{ },
  q{SELECT relname, array_to_string(reloptions, ',') FROM pg_class},
  q{WHERE relname IN ('categories', 'spaces') AND relkind = 'r'},
  q{AND pg_table_is_visible(oid) ORDER BY relname};
const my $CORPUS_SQL => join q{ },
  q{INSERT INTO search_documents},
  q{(search_document_id, entity_type, entity_id, category_id,},
  q{author_user_id, space_id, visibility, permission_scope,},
  q{visibility_version, permission_version, language, title,},
  q{body, search_vector, source_version, source_created_at)},
  q{SELECT gen_random_uuid(), 'post', gen_random_uuid(),},
  q{c.category_id, ?, c.space_id, 'public', 'public', 1, 1,},
  q{'simple', 'Reply ' || n, d.body,},
  q{to_tsvector('simple', 'Reply ' || n || ' ' || d.body), 1,},
  q{now() - make_interval(mins => n)},
  q{FROM generate_series(1, ?) AS n},
  q{CROSS JOIN LATERAL (},
  q{SELECT 'the reply number ' || n || ' is about topic' || (n % 97)},
  q{|| CASE WHEN n % ? = 1 THEN ' zymurgy' ELSE '' END AS body) d},
  q{CROSS JOIN (SELECT category_id, space_id FROM categories},
  q{WHERE deleted_at IS NULL AND visibility = 'public'},
  q{ORDER BY category_id LIMIT 1) c};
const my @UNUSABLE_INDEXES => qw(
  idx_search_documents_public_latest
  idx_search_documents_public_title_prefix
  idx_search_documents_public_filter_rank
  idx_search_documents_source_created
);

# Every search used to be a sequential scan of search_documents: the tsquery
# read its configuration from a column of the same row, the fuzzy arm was
# similarity(...) >= ? rather than a pg_trgm operator, and an OR needs every
# arm indexable before the planner will build a BitmapOr. The unit tier pins
# the SQL shape; only a database can say whether an index is usable.
#
# Then a word most documents hold was ranked over all of them (8.10): 100 ms
# at 20,000 documents and linear beyond. Search now ranks the newest
# candidate_limit matches only, which idx_search_documents_created serves by
# walking from the newest document and stopping, and runs under its own
# statement_timeout. This pins both plans on a corpus large enough for the
# planner to choose between them, and the timeout.
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

my %index = map { $_ => 1 } @{
    $dbh->selectcol_arrayref(
        q{SELECT indexname FROM pg_indexes WHERE tablename = 'search_documents'}
    )
};
ok( $index{idx_search_documents_created},
    'search_documents has the newest-first candidate index' );
is_deeply( [ grep { $index{$_} } @UNUSABLE_INDEXES ],
    [], 'and not the partial indexes no statement could use' );

# The planner walks that index only when it can tell how many matches survive
# the join to categories and spaces. Both are too small for autovacuum's
# default threshold to ever analyse them; on a never-analysed table's guesses
# it read and sorted every match again.
is_deeply(
    $dbh->selectall_arrayref($ANALYZE_THRESHOLDS_SQL),
    [
        [ categories => 'autovacuum_analyze_threshold=0' ],
        [ spaces     => 'autovacuum_analyze_threshold=0' ],
    ],
    'categories and spaces are analysed whenever they change'
);

my $member = $dbh->selectrow_array('SELECT id FROM users ORDER BY id LIMIT 1');
my $searcher = GPForum::Service::Search::Searcher->new(
    schema            => $schema,
    permission_engine =>
      GPForum::Service::Search::PermissionEngine->new( schema => $schema ),
);
my @viewers = (
    [ anonymous => { viewer  => GPForum::Service::Forum::Viewer->anonymous } ],
    [ member    => { user_id => $member } ],
);

for my $viewer (@viewers) {
    my ( $label, $actor ) = @{$viewer};

    my $results =
      $searcher->search( $actor, 'performance', { limit => $LIMIT } );
    ok( scalar @{$results}, "$label: a full-text search finds documents" );

    # Sequential and plain index scans off: the candidate index cannot serve
    # the match, so the plan shows whether the match arms can. A Seq Scan that
    # survives means no index could.
    my $plan = _bitmap_plan(
        $searcher->search_resultset(
            $actor, 'performance', { limit => $LIMIT }
        )
    );
    unlike(
        $plan,
        qr/Seq \s Scan \s on \s search_documents/msx,
        "$label: an index can serve the match"
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

_seed_corpus();

for my $viewer (@viewers) {
    my ( $label, $actor ) = @{$viewer};

    # 'the' is in every document of the corpus.
    my $common = _analyzed_plan(
        $searcher->search_resultset( $actor, 'the', { limit => $LIMIT } ) );
    my @common_scans = _document_scans($common);
    is( scalar @common_scans, 1, "$label: a common word reads the table once" );
    is(
        _scan_name( $common_scans[0] ),
        'Index Scan:idx_search_documents_created',
        "$label: by walking the newest-first index"
    ) or diag explain $common;
    cmp_ok( $common_scans[0]{'Actual Rows'},
        q{<=}, $CANDIDATES,
        "$label: and stops at the candidate cap, not the corpus" );

    my $capped = $searcher->ranked_search( $actor, 'the', { limit => $LIMIT } );
    is( scalar @{ $capped->{results} }, $LIMIT, "$label: it fills the page" );
    is( $capped->{ranking_capped},
        1, "$label: and says the ranking was capped" );

    my $rare = _analyzed_plan(
        $searcher->search_resultset( $actor, 'zymurgy', { limit => $LIMIT } ) );
    my @rare_scans = _document_scans($rare);
    is_deeply(
        [ map { _scan_name($_) } @rare_scans ],
        ['Bitmap Heap Scan:'],
        "$label: a rare word keeps the bitmap"
    ) or diag explain $rare;
    ok( _has_node( $rare, 'idx_search_documents_vector' ),
        "$label: over the GIN index" );

    my $found = $searcher->ranked_search( $actor, 'zymurgy', {} );
    is( scalar @{ $found->{results} },
        $RARE_MATCHES, "$label: it finds every match" );
    is( $found->{ranking_capped}, 0, "$label: and ranks them all" );
}

# The timeout. Another connection holds search_documents, so a search waits
# on its lock: without its own timeout it would wait for lock_timeout (3 s),
# holding the web worker; with it, it is cancelled at 200 ms and the error
# reaches the controller, which renders the page degraded.
my $timed = GPForum::Service::Search::Searcher->new(
    permission_engine =>
      GPForum::Service::Search::PermissionEngine->new( schema => $schema ),
    schema               => $schema,
    statement_timeout_ms => $TIMEOUT_MS,
);
my $holder = GPForum::Test::PostgresHarness::connect_dbi( $database->{dsn} );
$holder->begin_work;
$holder->do('LOCK TABLE search_documents IN ACCESS EXCLUSIVE MODE');

for my $call (
    [ search       => sub { $timed->search( undef, 'the', {} ) } ],
    [ autocomplete => sub { $timed->autocomplete( undef, 'reply', {} ) } ],
  )
{
    my ( $name, $code ) = @{$call};
    my $started = time;
    my $ok      = eval { $code->(); 1 };
    my $error   = $EVAL_ERROR;
    my $elapsed = ( time - $started ) * $MILLISECONDS;

    ok( !$ok, "$name: a search that runs long fails" );
    like(
        $error,
        qr/canceling [ ] statement [ ] due [ ] to [ ] statement [ ] timeout/msx,
        "$name: cancelled by the search statement timeout"
    );
    cmp_ok( $elapsed, q{<}, $LOCK_TIMEOUT_MS,
        "$name: before any other timeout would have ended it" );
}

$holder->rollback;
$holder->disconnect;

is( $dbh->selectrow_array('SHOW statement_timeout'),
    $SESSION_TIMEOUT,
    'the timeout was local: the connection keeps the one every query gets' );
ok( scalar @{ $timed->search( undef, 'the', { limit => $LIMIT } ) },
    'and the next search runs' );

$schema->storage->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

# A forum's worth of replies: every one holds 'the', a few hold 'zymurgy'.
# VACUUM flushes the GIN pending list the bulk insert filled, as autovacuum
# would, and ANALYZE gives the planner the word frequencies it chooses by and
# the statistics on categories and spaces that autovacuum gathers in
# production once migration 048 lowered their threshold.
sub _seed_corpus {
    $dbh->do( $CORPUS_SQL, undef, $member, $CORPUS, $RARE_EVERY );
    $dbh->do('VACUUM ANALYZE');

    return;
}

sub _bitmap_plan {
    my ($resultset) = @_;

    my ( $sql, @bind ) = _statement($resultset);
    $dbh->begin_work;
    $dbh->do('SET LOCAL enable_seqscan = off');
    $dbh->do('SET LOCAL enable_indexscan = off');
    my $lines =
      $dbh->selectcol_arrayref( "EXPLAIN (COSTS OFF) $sql", undef, @bind );
    $dbh->rollback;

    return join "\n", @{$lines};
}

sub _analyzed_plan {
    my ($resultset) = @_;

    my ( $sql, @bind ) = _statement($resultset);
    my ($json) = $dbh->selectrow_array( "EXPLAIN (ANALYZE, FORMAT JSON) $sql",
        undef, @bind );

    return decode_json($json)->[0]{Plan};
}

sub _statement {
    my ($resultset) = @_;

    my ( $sql, @bind ) = @{ ${ $resultset->as_query } };

    return ( $sql, map { ref $_ eq 'ARRAY' ? $_->[1] : $_ } @bind );
}

sub _document_scans {
    my ($plan) = @_;

    return
      grep { ( $_->{'Relation Name'} // q{} ) eq 'search_documents' }
      _nodes($plan);
}

sub _has_node {
    my ( $plan, $index ) = @_;

    return grep { ( $_->{'Index Name'} // q{} ) eq $index } _nodes($plan);
}

sub _scan_name {
    my ($node) = @_;

    return ( $node->{'Node Type'} // q{} ) . q{:}
      . ( $node->{'Index Name'}   // q{} );
}

sub _nodes {
    my ($node) = @_;

    return ( $node, map { _nodes($_) } @{ $node->{Plans} || [] } );
}

1;
