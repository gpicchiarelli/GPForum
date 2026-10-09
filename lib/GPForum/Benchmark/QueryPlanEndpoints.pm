# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Benchmark::QueryPlanEndpoints;

use v5.40;

use Const::Fast;
use Exporter     qw(import);
use MIME::Base64 qw(encode_base64url);

use GPForum::Benchmark::SeedDataset qw(seed_id);
use GPForum::Config;
use GPForum::Service::Clock;
use GPForum::Service::Community::FeedReader;
use GPForum::Service::Forum::CategoryReader;
use GPForum::Service::Forum::PostReader;
use GPForum::Service::Forum::Readability;
use GPForum::Service::Forum::ThreadReader;
use GPForum::Service::Forum::Viewer;
use GPForum::Service::Moderation::ReportStore;
use GPForum::Service::Notification::Dispatcher;
use GPForum::Service::Operations::MetricsSnapshot;
use GPForum::Service::Operations::Readiness;
use GPForum::Service::Outbox::ClaimQuery;
use GPForum::Service::Search::PermissionEngine;
use GPForum::Service::Search::Searcher;

our $VERSION = '0.001';

our @EXPORT_OK =
  qw(endpoint_definition endpoint_names page_rows read_deep_page);

# The benchmark's seeded ids: the first category, thread and user, and a
# second category the signed-in reader holds a grant on.
const my $CATEGORY_ID         => seed_id( category => 1 );
const my $GRANTED_CATEGORY_ID => seed_id( category => 2 );
const my $SPACE_ID            => seed_id( space    => 1 );
const my $THREAD_ID           => seed_id( thread   => 1 );
const my $USER_ID             => seed_id( user     => 1 );
const my $PAGE_ROWS           => 26;

# The deep pages' cursors: the row halfway down the longest thread, the
# largest category and the latest public threads, in each reader's own
# order. Halfway, because a scan that ignores the cursor shows either way
# from there: walking from the top it filters out the first half, fetching
# what follows the cursor it sorts the second. Read outside the plans, once
# per report: the window runs over one thread or one category, though finding
# the longest thread counts every thread's posts.
const my $DEEP_THREAD_SQL => join q{ },
  'WITH longest AS (SELECT thread_id FROM posts GROUP BY thread_id',
  'ORDER BY count(*) DESC, thread_id LIMIT 1),',
  'ranked AS (SELECT p.thread_id, p.position, p.post_id,',
  'row_number() OVER (ORDER BY p.position, p.post_id) AS rank,',
  'count(*) OVER () AS total FROM posts p JOIN longest USING (thread_id))',
  'SELECT r.thread_id, t.category_id, c.space_id, r.position, r.post_id,',
  'r.rank - 1 AS depth FROM ranked r JOIN threads t USING (thread_id)',
  'JOIN categories c ON c.category_id = t.category_id',
  'WHERE r.rank = (r.total + 1) / 2';
const my $DEEP_CATEGORY_SQL => join q{ },
  'WITH largest AS (SELECT category_id FROM threads WHERE deleted_at IS NULL',
  'GROUP BY category_id ORDER BY count(*) DESC, category_id LIMIT 1),',
  'ranked AS (SELECT t.category_id, t.pinned, t.last_activity_at,',
  't.thread_id, row_number() OVER (ORDER BY t.pinned DESC,',
  't.last_activity_at DESC, t.thread_id DESC) AS rank,',
  'count(*) OVER () AS total FROM threads t JOIN largest USING (category_id)',
  'WHERE t.deleted_at IS NULL)',
  'SELECT r.category_id, c.space_id, r.pinned, r.last_activity_at,',
  'r.thread_id, r.rank - 1 AS depth FROM ranked r',
  'JOIN categories c USING (category_id) WHERE r.rank = (r.total + 1) / 2';
const my $DEEP_LATEST_SQL => join q{ },
  'WITH ranked AS (SELECT t.last_activity_at, t.thread_id,',
  'row_number() OVER (ORDER BY t.last_activity_at DESC, t.thread_id DESC)',
  'AS rank, count(*) OVER () AS total FROM threads t',
  q{WHERE t.deleted_at IS NULL AND t.visibility = 'public'},
  q{AND t.moderation_state IN ('visible', 'locked'))},
  'SELECT last_activity_at, thread_id, rank - 1 AS depth FROM ranked',
  'WHERE rank = (total + 1) / 2';

# Each list's cursor, as its reader mints it: PageWindow joins the sort value
# and the id, ThreadReader leads the category's with pinned. Written out here
# because the readers mint cursors only from the rows of a page they fetched;
# a cursor the reader no longer accepts shows as cursor_ignored, not as a
# deep page that passed.
const my %DEEP_PAGE => (
    category => {
        sql    => $DEEP_CATEGORY_SQL,
        cursor => [qw(pinned last_activity_at thread_id)],
    },
    latest => {
        sql    => $DEEP_LATEST_SQL,
        cursor => [qw(last_activity_at thread_id)],
    },
    thread => {
        sql    => $DEEP_THREAD_SQL,
        cursor => [qw(position post_id)],
    },
);
const my $SEARCH_ROWS         => 20;
const my $AUTOCOMPLETE_ROWS   => 10;
const my $CLAIM_ROWS          => 100;
const my $CLAIM_LEASE_SECONDS => 60;
const my @ENDPOINT_NAMES => qw(
  home
  categories
  category_threads
  category_threads_signed_in
  thread_view
  search
  autocomplete
  feed
  notifications outbox_claim
  moderation_queue
  health_ready
  metrics
  home_signed_in
  home_deep
  category_threads_deep
  category_threads_deep_signed_in
  thread_view_signed_in
  thread_view_deep
  thread_view_deep_signed_in
);

# What each endpoint EXPLAINs: its purpose and label, and the resultset lib/
# builds for it -- or, where lib/ issues raw SQL, lib/'s statement. A deep
# endpoint's resultset takes the page halfway down the list it reads.
my %ENDPOINT = (
    home => {
        purpose   => 'latest public thread listing',
        sql_label => 'threads_public_activity',
        resultset => sub ($schema) {
            return _latest_threads( $schema, _seeded_page() );
        },
    },
    home_signed_in => {
        purpose   => 'latest public thread listing, member with a grant',
        sql_label => 'threads_public_activity_viewer',
        resultset => sub ($schema) {
            return _latest_threads( $schema, _seeded_page(), _member_viewer() );
        },
    },
    home_deep => {
        purpose   => 'latest public thread listing, halfway down',
        sql_label => 'threads_public_activity_keyset',
        deep      => 'latest',
        resultset => \&_latest_threads,
    },
    categories => {
        purpose   => 'category index',
        sql_label => 'categories_position',
        resultset => sub ($schema) {
            return GPForum::Service::Forum::CategoryReader->new(
                schema => $schema )->categories_resultset($PAGE_ROWS);
        },
    },
    category_threads => {
        purpose   => 'keyset category thread list, anonymous',
        sql_label => 'threads_category_activity_visible_locked',
        resultset => sub ($schema) {
            return _category_threads( $schema, _seeded_page() );
        },
    },
    category_threads_signed_in => {
        purpose   => 'keyset category thread list, signed in',
        sql_label => 'threads_category_viewer_union',
        resultset => sub ($schema) {
            return _category_threads( $schema, _seeded_page(),
                _member_viewer() );
        },
    },
    category_threads_deep => {
        purpose   => 'keyset category thread list, halfway down',
        sql_label => 'threads_category_activity_keyset',
        deep      => 'category',
        resultset => \&_category_threads,
    },
    category_threads_deep_signed_in => {
        purpose   => 'keyset category thread list, halfway down, signed in',
        sql_label => 'threads_category_viewer_union_keyset',
        deep      => 'category',
        resultset => sub ( $schema, $page ) {
            return _category_threads( $schema, $page, _member_viewer() );
        },
    },
    thread_view => {
        purpose   => 'thread post page with current body',
        sql_label => 'posts_visible_thread_position',
        resultset => sub ($schema) {
            return _thread_posts( $schema, _seeded_page() );
        },
    },
    thread_view_signed_in => {
        purpose   => 'thread post page, signed in',
        sql_label => 'posts_thread_position_viewer',
        resultset => sub ($schema) {
            return _thread_posts( $schema, _seeded_page(), _member_viewer() );
        },
    },
    thread_view_deep => {
        purpose   => 'thread post page halfway down the longest thread',
        sql_label => 'posts_visible_thread_position_keyset',
        deep      => 'thread',
        resultset => \&_thread_posts,
    },
    thread_view_deep_signed_in => {
        purpose =>
          'thread post page halfway down the longest thread, signed in',
        sql_label => 'posts_thread_position_viewer_keyset',
        deep      => 'thread',
        resultset => sub ( $schema, $page ) {
            return _thread_posts( $schema, $page, _member_viewer() );
        },
    },

    # Ordered by relevance over the newest candidate_limit matches only
    # (8.10). For a word most documents hold the planner walks
    # idx_search_documents_created and stops at the cap: at 30,000
    # documents that all hold it, this records no sequential scan and no
    # warning. That needs statistics on categories and spaces (migration
    # 048); without them the planner reads and sorts every match again.
    search => {
        purpose         => 'permission-safe PostgreSQL search projection',
        ranked_relation => 'search_documents',
        sql_label       => 'search_documents_vector',
        resultset       => sub ($schema) {
            return _searcher($schema)
              ->search_resultset( undef,
                'performance', { limit => $SEARCH_ROWS } );
        },
    },
    autocomplete => {
        purpose         => 'permission-safe PostgreSQL autocomplete projection',
        ranked_relation => 'search_documents',
        sql_label       => 'search_documents_title_trgm',
        resultset       => sub ($schema) {
            return _searcher($schema)
              ->autocomplete_resultset( undef,
                'perf', { limit => $AUTOCOMPLETE_ROWS } );
        },
    },
    feed => {
        purpose   => 'user feed projection',
        sql_label => 'user_feed_items_user_created',
        resultset => sub ($schema) {
            return GPForum::Service::Community::FeedReader->new(
                readability => _readability($schema),
                schema      => $schema,
            )->feed_resultset( $USER_ID, { limit => $PAGE_ROWS } );
        },
    },
    notifications => {
        purpose   => 'notification inbox page',
        sql_label => 'notification_inbox_recipient_created',
        resultset => sub ($schema) {
            return GPForum::Service::Notification::Dispatcher->new(
                readability => _readability($schema),
                schema      => $schema,
            )->inbox_resultset( $USER_ID, { limit => $PAGE_ROWS } );
        },
    },
    moderation_queue => {
        purpose   => 'moderation report queue',
        sql_label => 'reports_queue',
        resultset => sub ($schema) {
            return GPForum::Service::Moderation::ReportStore->new(
                schema => $schema )->queue_resultset( { limit => $PAGE_ROWS } );
        },
    },

    # A one-row read of the event log, the largest table readiness
    # touches. A sequential scan cut at one row is the cheapest answer.
    health_ready => {
        purpose        => 'readiness table probe',
        sql_label      => 'readiness_event_log_probe',
        allow_seq_scan => 1,
        resultset      => sub ($schema) {
            return GPForum::Service::Operations::Readiness->new(
                schema => $schema )->probe_resultset('EventLog');
        },
    },
    metrics => {
        purpose   => 'outbox retry backlog metric',
        sql_label => 'outbox_retry_backlog',
        resultset => sub ($schema) {
            return GPForum::Service::Operations::MetricsSnapshot->new(
                schema => $schema )->retry_backlog_resultset->count_rs;
        },
    },
    outbox_claim => {
        purpose   => 'outbox worker ready-claim scan',
        sql_label => 'outbox_claim_ready',
        statement => \&_claim_statement,
    },
);

# The feed and the inbox filter on what the benchmark user can read, as they
# do in the application.
sub _readability ($schema) {
    return GPForum::Service::Forum::Readability->new( schema => $schema );
}

# The seeded benchmark ids, without a cursor: the page every list endpoint
# that is not a deep one reads.
sub _seeded_page {
    return {
        after       => undef,
        category_id => $CATEGORY_ID,
        depth       => 0,
        space_id    => $SPACE_ID,
        thread_id   => $THREAD_ID,
    };
}

# The signed-in reader: an account (a member, ADR 0102) with a category.read
# grant on another category than the one paged, as a member with any grant
# usually is. Its conditions carry both branches a member adds -- the
# members' level and their own private rows -- and, on the home page, the
# granted category.
sub _member_viewer {
    return GPForum::Service::Forum::Viewer->new(
        category_ids => [$GRANTED_CATEGORY_ID],
        member       => 1,
        user_id      => $USER_ID,
    );
}

# What HomePageReader asks ThreadReader for.
sub _latest_threads ( $schema, $page, $viewer = undef ) {
    return GPForum::Service::Forum::ThreadReader->new( schema => $schema )
      ->latest_threads_resultset(
        { after => $page->{after}, ( $viewer ? ( viewer => $viewer ) : () ) } );
}

# What Controller::Forum asks ThreadReader for: a signed-in reader adds the
# account and its grants decided for the category.
sub _category_threads ( $schema, $page, $viewer = undef ) {
    return GPForum::Service::Forum::ThreadReader->new( schema => $schema )
      ->category_threads_resultset(
        {
            after       => $page->{after},
            category_id => $page->{category_id},
            _signed_in( $page, $viewer ),
        }
      );
}

# What ThreadDetailReader asks PostReader for, the same way.
sub _thread_posts ( $schema, $page, $viewer = undef ) {
    return GPForum::Service::Forum::PostReader->new( schema => $schema )
      ->thread_posts_resultset(
        {
            after     => $page->{after},
            thread_id => $page->{thread_id},
            _signed_in( $page, $viewer ),
        }
      );
}

sub _signed_in ( $page, $viewer ) {
    return if !$viewer;

    return (
        viewer_scope   => $viewer->within( @{$page}{qw(category_id space_id)} ),
        viewer_user_id => $viewer->user_id,
    );
}

# Search ranks under the configured candidate cap, as the application's does.
# The cap is the inner LIMIT, which decides between walking
# idx_search_documents_created and sorting every match, so evidence taken at
# Searcher's default described a statement a forum with another cap never sent.
sub _searcher ($schema) {
    return GPForum::Service::Search::Searcher->new(
        candidate_limit =>
          GPForum::Config->from_environment->search_candidate_limit,
        permission_engine =>
          GPForum::Service::Search::PermissionEngine->new( schema => $schema ),
        schema => $schema,
    );
}

# The claim is raw SQL in lib/, so it is taken from there with the binds a
# worker would send.
sub _claim_statement {
    my $clock = GPForum::Service::Clock->new;
    my $claim = GPForum::Service::Outbox::ClaimQuery->new;

    return [
        $claim->sql,
        @{
            $claim->bind_values(
                {
                    limit        => $CLAIM_ROWS,
                    locked_until =>
                      $clock->epoch_plus_iso8601($CLAIM_LEASE_SECONDS),
                    now       => $clock->now_iso8601,
                    worker_id => 'query-plan-evidence',
                }
            )
        }
    ];
}

sub endpoint_names {
    return @ENDPOINT_NAMES;
}

# The endpoint's definition, undef for a name it does not know.
sub endpoint_definition ($endpoint) {
    return $ENDPOINT{$endpoint};
}

# The rows a list page holds.
sub page_rows {
    return $PAGE_ROWS;
}

# The thread, category or latest thread halfway down, and its cursor. A
# database with nothing to page through gets the seeded ids' first page,
# which the depth evidence flags no_deep_page.
sub read_deep_page ( $dbh, $kind ) {
    my $deep = $DEEP_PAGE{$kind};
    my $row  = $dbh->selectrow_hashref( $deep->{sql} );
    return _seeded_page() if !$row;

    return {
        %{ _seeded_page() },
        %{$row},
        after => encode_base64url(
            join q{|}, map { $_ // q{} } @{$row}{ @{ $deep->{cursor} } }
        ),
        depth => 0 + ( $row->{depth} // 0 ),
    };
}

1;

__END__

=head1 NAME

GPForum::Benchmark::QueryPlanEndpoints - What the query plan evidence EXPLAINs.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use GPForum::Benchmark::QueryPlanEndpoints qw(
      endpoint_definition endpoint_names read_deep_page
    );

    for my $name ( endpoint_names() ) {
        my $definition = endpoint_definition($name);
        my $page = $definition->{deep}
          ? read_deep_page( $dbh, $definition->{deep} ) : undef;
    }

=head1 DESCRIPTION

The endpoints L<GPForum::Command::QueryPlanEvidence> gathers evidence for,
each defined by the resultset the application's own readers build for it
over the seeded benchmark ids (L<GPForum::Benchmark::SeedDataset>), or by
the raw statement C<lib/> sends, so changing a reader's query changes what is
EXPLAINed. A deep endpoint reads the page halfway down its list.

=head1 SUBROUTINES/METHODS

=head2 endpoint_names

The endpoint names, in the order a report lists them.

=head2 endpoint_definition

Given a name, a hash reference with the endpoint's C<purpose>, C<sql_label>,
and either a C<resultset> sub (given the schema and, for a C<deep> endpoint,
the page) or a C<statement> sub answering C<[ $sql, @bind ]>; optionally
C<deep> (C<category>, C<latest> or C<thread>), C<ranked_relation> and
C<allow_seq_scan>. Undef for a name it does not know.

=head2 read_deep_page

Given a database handle and a kind of list, the page halfway down it: the
seeded ids, the row's own columns, the reader's cursor (C<after>) and the
C<depth>. With nothing to page through, the seeded first page, without a
cursor.

=head2 page_rows

The rows a list page holds, 26.

=head1 DIAGNOSTICS

None: a failing query raises the handle's error.

=head1 CONFIGURATION AND ENVIRONMENT

The search candidate cap is read from the environment through L<GPForum::Config>.

=head1 DEPENDENCIES

L<Const::Fast>, L<Exporter>, L<MIME::Base64>, L<GPForum::Config>, and the readers and stores whose resultsets it EXPLAINs.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
