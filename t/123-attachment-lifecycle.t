package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Service::Attachment::Lifecycle;
use GPForum::Test::FixedClock;
use Test::More;

our $VERSION = '0.001';

const my $DEFAULT_ORPHAN_LIMIT  => 100;
const my $EXPLICIT_ORPHAN_LIMIT => 10;
const my $LINKS_PER_POST        => 10;
const my $TWO_POSTS             => 2;

my $lifecycle = GPForum::Service::Attachment::Lifecycle->new(
    clock => GPForum::Test::FixedClock->new, );

ok( !$lifecycle->already_uploaded( { state => 'intent' } ),
    'already_uploaded rejects an intent row' );
ok(
    $lifecycle->already_uploaded( { state => 'uploaded' } ),
    'already_uploaded accepts a row that left intent'
);

my $uploaded = {
    attachment_id => 'att-1',
    state         => 'uploaded',
    uploaded_at   => '2026-05-23T12:00:00Z',
};
is_deeply(
    $lifecycle->uploaded_replay($uploaded),
    {
        attachment_id => 'att-1',
        idempotent    => 1,
        state         => 'uploaded',
        uploaded_at   => '2026-05-23T12:00:00Z',
    },
    'uploaded_replay keeps the stored upload fields'
);

is( $lifecycle->scan_state( { scan_status => 'clean' } ),
    'available', 'scan_state maps a clean scan to available' );
is( $lifecycle->scan_state( { scan_status => 'infected' } ),
    'quarantined', 'scan_state maps any other scan to quarantined' );

my $clean_row = {
    scan_status => 'clean',
    state       => 'available',
};
ok(
    $lifecycle->scan_matches( $clean_row, { scan_status => 'clean' } ),
    'scan_matches accepts an already-applied clean scan'
);
ok( !$lifecycle->scan_matches( $clean_row, { scan_status => 'infected' } ),
    'scan_matches rejects a different scan status' );
is_deeply(
    $lifecycle->replayed_scan(
        $clean_row, { attachment_id => 'att-1', scan_status => 'clean' }
    ),
    {
        attachment_id => 'att-1',
        idempotent    => 1,
        scan_status   => 'clean',
        state         => 'available',
    },
    'replayed_scan returns the idempotent clean scan hash'
);
ok(
    !$lifecycle->replayed_scan(
        $clean_row, { attachment_id => 'att-1', scan_status => 'infected' }
    ),
    'replayed_scan ignores a scan that has not been applied'
);

is_deeply(
    $lifecycle->scan_changes( { scan_status => 'clean' } ),
    {
        scanned_at  => '2026-05-23T12:00:00Z',
        scan_status => 'clean',
        state       => 'available',
    },
    'scan_changes writes available columns for a clean scan'
);
is_deeply(
    $lifecycle->scan_changes( { scan_status => 'infected' } ),
    {
        quarantined_at => '2026-05-23T12:00:00Z',
        scanned_at     => '2026-05-23T12:00:00Z',
        scan_status    => 'infected',
        state          => 'quarantined',
    },
    'scan_changes records quarantined_at for an infected scan'
);

ok( $lifecycle->already_deleted( { state => 'deleted' } ),
    'already_deleted accepts a deleted row' );
ok( !$lifecycle->already_deleted( { state => 'available' } ),
    'already_deleted rejects a live row' );
is_deeply(
    $lifecycle->deleted_replay(
        {
            attachment_id => 'att-1',
            state         => 'deleted',
        }
    ),
    {
        attachment => {
            attachment_id => 'att-1',
            state         => 'deleted',
        },
        idempotent => 1,
        ok         => 1,
    },
    'deleted_replay keeps the stored attachment hash'
);

is( $lifecycle->orphan_limit( {} ),
    $DEFAULT_ORPHAN_LIMIT, 'orphan_limit defaults to one hundred candidates' );
is( $lifecycle->orphan_limit( { limit => $EXPLICIT_ORPHAN_LIMIT } ),
    $EXPLICIT_ORPHAN_LIMIT, 'orphan_limit keeps an explicit row cap' );
is(
    $lifecycle->orphan_reason( {} ),
    'orphan cleanup',
    'orphan_reason defaults to orphan cleanup'
);
is( $lifecycle->orphan_reason( { reason => 'stale intent' } ),
    'stale intent', 'orphan_reason keeps an explicit reason' );
is(
    $lifecycle->orphan_actor(
        { owner_user_id => 'owner-1' },
        { actor_id      => 'worker' },
    ),
    'worker',
    'orphan_actor prefers the supplied actor'
);
is( $lifecycle->orphan_actor( { owner_user_id => 'owner-1' }, {} ),
    'owner-1', 'orphan_actor falls back to the attachment owner' );
is_deeply(
    $lifecycle->orphan_where,
    { state => 'intent' },
    'orphan_where selects intent rows'
);
is_deeply(
    $lifecycle->orphan_search_attrs( { limit => $EXPLICIT_ORPHAN_LIMIT } ),
    {
        order_by => [ { -asc => 'created_at' } ],
        rows     => $EXPLICIT_ORPHAN_LIMIT,
    },
    'orphan_search_attrs uses oldest-first order and the row cap'
);
is_deeply(
    $lifecycle->cleanup_result( ['att-1'] ),
    {
        deleted => ['att-1'],
        ok      => 1,
    },
    'cleanup_result keeps deleted rows and ok'
);

is( $lifecycle->links_per_post,
    $LINKS_PER_POST, 'links_per_post keeps the per-post cap' );
is( $lifecycle->post_link_target,
    'post', 'post_link_target keeps the post target' );
is(
    $lifecycle->post_link_rows( [ 'post-1', 'post-2' ] ),
    $LINKS_PER_POST * $TWO_POSTS,
    'post_link_rows scales the cap by post count'
);
is( $lifecycle->link_lookup_rows,
    $LINKS_PER_POST, 'link_lookup_rows keeps the per-attachment cap' );

done_testing();

1;
