# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::QueryPlanEvidence;
use GPForum::Test::QueryPlanEvidenceDbh;

our $VERSION = '0.001';

# What the query plan evidence reports beside its verdicts: the summary of
# each plan, the thresholds it judged them by, the depth below which a deep
# page only warns, the seeded ids it EXPLAINs and the text of an empty list.
# The command was split into Benchmark::QueryPlanEndpoints and PlanRules;
# none of these was pinned, and a lost one would only show as evidence that
# describes another plan or another page than the one it names.

const my $CATEGORY_ID    => '018f1001-0001-7000-8000-000000000001';
const my $THREAD_ID      => '018f1004-0001-7000-8000-000000000001';
const my $USER_ID        => '018f1002-0001-7000-8000-000000000001';
const my $DEEP_PAGE_MIN  => 52;
const my $SHARED_HIT     => 7;
const my $SHARED_READ    => 3;
const my $PLAN_ROWS      => 10;
const my $ACTUAL_ROWS    => 9;
const my $TOTAL_COST     => 1.5;
const my $ACTUAL_TIME_MS => 0.25;
const my %DEEP_THREAD => (
    category_id => $CATEGORY_ID,
    position    => '500',
    post_id     => '018f1005-01f4-7000-8000-0000000001f4',
    space_id    => '018f1000-0001-7000-8000-000000000001',
    thread_id   => '018f1004-0007-7000-8000-000000000007',
);

_test_summary();
_test_failure_rule();
_test_shallow_page();
_test_seeded_ids();
_test_empty_lists_text();

done_testing();

sub _test_summary {
    my $plan = {
        Plan => {
            'Node Type'          => 'Index Scan',
            'Relation Name'      => 'threads',
            'Plan Rows'          => $PLAN_ROWS,
            'Actual Rows'        => $ACTUAL_ROWS,
            'Total Cost'         => $TOTAL_COST,
            'Actual Total Time'  => $ACTUAL_TIME_MS,
            'Shared Hit Blocks'  => $SHARED_HIT,
            'Shared Read Blocks' => $SHARED_READ,
        },
    };
    is_deeply(
        _report( { plan => $plan }, 'home' )->{summary},
        {
            root_node      => 'Index Scan',
            plan_rows      => $PLAN_ROWS,
            actual_rows    => $ACTUAL_ROWS,
            total_cost     => $TOTAL_COST,
            actual_time_ms => $ACTUAL_TIME_MS,
            shared_hit     => $SHARED_HIT,
            shared_read    => $SHARED_READ,
        },
        'a plan\'s summary carries its rows, cost, time and buffers apart'
    );

    my $bare = { Plan => { 'Node Type' => 'Index Scan' } };
    is_deeply(
        _report( { plan => $bare }, 'home' )->{summary},
        {
            root_node      => 'Index Scan',
            plan_rows      => 0,
            actual_rows    => 0,
            total_cost     => 0,
            actual_time_ms => 0,
            shared_hit     => 0,
            shared_read    => 0,
        },
        'and zero for what a plan taken without ANALYZE or BUFFERS lacks'
    );

    return;
}

sub _test_failure_rule {
    my $report =
      GPForum::Command::QueryPlanEvidence->new(
        dbh => GPForum::Test::QueryPlanEvidenceDbh->new )
      ->evidence_report(
        { analyze => 0, dry_run => 0, endpoints => ['home'] } );

    is_deeply(
        $report->{failure_rule},
        {
            seq_scan_plan_rows     => 100,
            seq_scan_relation_rows => 10_000,
            sort_plan_rows         => 1_000,
            nested_loop_plan_rows  => 5_000,
            deep_page_filter_rows  => 26,
            deep_page_min_rows     => $DEEP_PAGE_MIN,
        },
        'the report states the thresholds it judged its plans by'
    );

    return;
}

# Fewer than two pages before the cursor only warns that the page is too
# shallow to tell; two pages and more do not.
sub _test_shallow_page {
    for my $case (
        [ $DEEP_PAGE_MIN - 1, ["shallow_page:@{[ $DEEP_PAGE_MIN - 1 ]}"] ],
        [ $DEEP_PAGE_MIN,     [] ],
      )
    {
        my ( $depth, $expected ) = @{$case};
        my $report =
          _report( { deep_page => { %DEEP_THREAD, depth => "$depth" } },
            'thread_view_deep' );
        is_deeply( [ grep { /\A shallow_page/msx } @{ $report->{warnings} } ],
            $expected, "a deep page $depth rows down" );
    }

    return;
}

sub _test_seeded_ids {
    for my $case (
        [ category_threads => $CATEGORY_ID, 'the first category' ],
        [ thread_view      => $THREAD_ID,   'the first thread' ],
        [ feed             => $USER_ID,     'the first user\'s feed' ],
        [ notifications    => $USER_ID,     'the first user\'s inbox' ],
      )
    {
        my ( $endpoint, $id, $what ) = @{$case};
        my $dbh = GPForum::Test::QueryPlanEvidenceDbh->new;
        GPForum::Command::QueryPlanEvidence->new( dbh => $dbh )
          ->evidence_report(
            { analyze => 0, dry_run => 0, endpoints => [$endpoint] } );
        my @binds = map { @{ $_->{bind} } }
          grep { $_->{sql} =~ /\A EXPLAIN [ ] [(] BUFFERS/msx }
          @{ $dbh->statements };

        ok(
            ( grep { defined && $_ eq $id } @binds ),
            "$endpoint EXPLAINs $what the seed writes"
        );
    }

    return;
}

sub _test_empty_lists_text {
    my $stdout = q{};
    open my $handle, '>', \$stdout or BAIL_OUT('cannot capture STDOUT');
    {
        local *STDOUT = $handle;
        GPForum::Command::QueryPlanEvidence->new->run( '--dry-run',
            '--endpoint', 'home' );
    }
    close $handle or BAIL_OUT('cannot close the captured STDOUT');

    is(
        $stdout,
        q{query_plan_evidence status=ok mode=dry-run analyze=1}
          . " dataset_profile=small\n"
          . 'endpoint=home status=ok sql_label=threads_public_activity'
          . " violations=none warnings=none \n",
        'an endpoint without violations or warnings says none of each'
    );

    return;
}

sub _report ( $dbh_input, $endpoint ) {
    return GPForum::Command::QueryPlanEvidence->new(
        dbh => GPForum::Test::QueryPlanEvidenceDbh->new( %{$dbh_input} ) )
      ->evidence_report(
        { analyze => 0, dry_run => 0, endpoints => [$endpoint] } )
      ->{endpoints}[0];
}

1;
