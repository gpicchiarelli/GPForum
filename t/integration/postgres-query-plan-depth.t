# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::QueryPlanEvidence;
use GPForum::Infrastructure::Keyset;
use GPForum::Service::Forum::ThreadReader;
use GPForum::Test::PgDatabase;

our $VERSION = '0.001';

const my $THREAD_ID        => '018f1004-0001-7000-8000-000000000001';
const my $CATEGORY_ID      => '018f1001-0001-7000-8000-000000000001';
const my $AUTHOR_ID        => '018f1002-0002-7000-8000-000000000002';
const my $SEEDED_POSTS     => 8;
const my $THREAD_POSTS     => 3_000;
const my $CATEGORY_THREADS => 1_500;
const my $DEEP_ENOUGH      => 700;
const my @ENDPOINTS => qw(
  home_signed_in
  home_deep
  category_threads_signed_in
  category_threads_deep
  category_threads_deep_signed_in
  thread_view_signed_in
  thread_view_deep
  thread_view_deep_signed_in
);
const my @DEEP_ENDPOINTS => grep { /_deep/msx } @ENDPOINTS;

# A long thread and a large category, both in the seed's first category: the
# thread's replies after the seed's eight, the category's threads older than
# the seed's, so the seed's pages stay where they were.
const my $POSTS_SQL => join q{ },
  q{INSERT INTO posts (post_id, thread_id, author_user_id, position)},
  q{SELECT gen_random_uuid(), ?, ?, n},
  q{FROM generate_series(?::bigint, ?::bigint) AS n};
const my $THREADS_SQL => join q{ },
  q{INSERT INTO threads (thread_id, category_id, author_user_id, title, slug,},
  q{last_activity_at) SELECT gen_random_uuid(), ?, ?, 'Depth ' || n,},
  q{'depth-' || n,},
  q{timestamptz '2026-01-01 00:00:00+00' + n * interval '1 minute'},
  q{FROM generate_series(1, ?::integer) AS n};

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the deep page plan test';
}

# The plan gate used to EXPLAIN first pages only, where a keyset predicate
# no index can start from costs nothing: page 800 of a long thread read
# every row before it (Infrastructure::Keyset). Here it EXPLAINs the page
# halfway down a 3,000-post thread and a 1,500-thread category, signed in and
# not, against PostgreSQL's own planner.
my $database = GPForum::Test::PgDatabase->fresh( seed => 1 );
my $dbh      = $database->dbh;
$dbh->do(
    $POSTS_SQL, undef, $THREAD_ID, $AUTHOR_ID,
    $SEEDED_POSTS + 1,
    $SEEDED_POSTS + $THREAD_POSTS
);
$dbh->do( $THREADS_SQL, undef, $CATEGORY_ID, $AUTHOR_ID, $CATEGORY_THREADS );
$dbh->do('ANALYZE posts');
$dbh->do('ANALYZE threads');

my $command =
  GPForum::Command::QueryPlanEvidence->new( schema => $database->schema );
my %report = _reports(@ENDPOINTS);
for my $endpoint (@ENDPOINTS) {
    is( $report{$endpoint}{status}, 'ok', "$endpoint passes the plan gate" )
      or diag explain $report{$endpoint};
}
for my $endpoint (@DEEP_ENDPOINTS) {
    cmp_ok( $report{$endpoint}{summary}{depth}{rows_before_cursor},
        '>', $DEEP_ENOUGH, "$endpoint pages deep into its list" );
    is_deeply(
        [
            grep { /shallow_page|no_deep_page|unmeasured/msx }
              @{ $report{$endpoint}{warnings} }
        ],
        [],
        'and measures what its page filtered'
    );
}

# The predicate as it was before Keyset bounded the sort column: the
# lexicographic OR alone. The gate has to fail it, on the deep pages that
# read their way to the cursor.
{
    local *GPForum::Infrastructure::Keyset::after = \&_unbounded_after;
    my %regressed =
      _reports(qw(home_deep thread_view_deep thread_view_deep_signed_in));
    for my $endpoint ( sort keys %regressed ) {
        like(
            join( q{,}, @{ $regressed{$endpoint}{violations} } ),
            qr/filter_grows_with_depth/msx,
            "an unbounded cursor fails $endpoint"
        );
    }
}

# The category list writes its own predicate, led by pinned, and its own
# bound; without the bound its deep pages read every thread before the
# cursor too, signed in or not. The bound is set inside the reader, so the
# regression is made there.
{
    my $bounded =
      GPForum::Service::Forum::ThreadReader->can('_visible_category_query');
    ## no critic (Variables::ProtectPrivateVars)
    local *GPForum::Service::Forum::ThreadReader::_visible_category_query =
      sub {
        my $query = $bounded->(@_);
        delete @{$query}{qw(me.pinned me.last_activity_at)};
        return $query;
      };
    ## use critic
    my %regressed =
      _reports(qw(category_threads_deep category_threads_deep_signed_in));
    for my $endpoint ( sort keys %regressed ) {
        like(
            join( q{,}, @{ $regressed{$endpoint}{violations} } ),
            qr/filter_grows_with_depth/msx,
            "an unbounded category cursor fails $endpoint"
        );
    }
}

done_testing();

sub _reports {
    my (@endpoints) = @_;

    my $evidence = $command->evidence_report(
        { analyze => 1, dry_run => 0, endpoints => \@endpoints } );

    return map { $_->{endpoint} => $_ } @{ $evidence->{endpoints} };
}

sub _unbounded_after {
    my ( undef, $query, $cursor ) = @_;

    my $past = ( $cursor->{direction} // 'asc' ) eq 'desc' ? q{<} : q{>};
    my ( $sort, $sort_value ) = @{ $cursor->{sort} };
    my ( $id, $id_value )     = @{ $cursor->{id} };
    $query->{-or} = [
        { $sort => { $past => $sort_value } },
        {
            -and =>
              [ { $sort => $sort_value }, { $id => { $past => $id_value } } ]
        },
    ];

    return $query;
}

1;
