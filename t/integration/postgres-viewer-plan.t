# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::ThreadReader;
use GPForum::Service::Identity::ProfileReader;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the viewer plan test';
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

# The thread at the top of a category page, deleted by its author: the one
# row a signed-in author must still see there and nobody else may.
my ( $thread_id, $category_id, $author_id ) = $dbh->selectrow_array(
    join q{ },
    'SELECT thread_id, category_id, author_user_id FROM threads',
    q{WHERE deleted_at IS NULL AND visibility = 'public'},
    q{AND moderation_state IN ('visible', 'locked')},
    'ORDER BY pinned DESC, last_activity_at DESC, thread_id DESC LIMIT 1'
);
my ($other_id) =
  $dbh->selectrow_array( 'SELECT id FROM users WHERE id <> ? LIMIT 1',
    undef, $author_id );
$dbh->do(
    'UPDATE threads SET deleted_at = now(), deleted_by = author_user_id'
      . ' WHERE thread_id = ?',
    undef, $thread_id
);
$dbh->do('ANALYZE threads');

my $threads = GPForum::Service::Forum::ThreadReader->new( schema => $schema );
my %viewer  = (
    author    => { category_id => $category_id, viewer_user_id => $author_id },
    other     => { category_id => $category_id, viewer_user_id => $other_id },
    anonymous => { category_id => $category_id },
);

ok( _listed( $threads, $viewer{author} ),
    'the author still sees their deleted thread on the category page' );
ok( !_listed( $threads, $viewer{other} ), 'another signed-in reader does not' );
ok( !_listed( $threads, $viewer{anonymous} ), 'nor does an anonymous reader' );

# Signed in, the page used to be "deleted_at IS NULL OR author_user_id = ?",
# which every category index -- partial on deleted_at IS NULL -- is unable to
# answer: with sequential scans disabled PostgreSQL still read the table.
for my $name (qw(author anonymous)) {
    my $plan = GPForum::Test::PostgresHarness::plan_without_seqscan( $dbh,
        $threads->category_threads_resultset( $viewer{$name} ) );
    unlike(
        $plan,
        qr/Seq [ ] Scan [ ] on [ ] threads/msx,
        "the $name category page reads threads through an index"
    ) or diag $plan;
    like(
        $plan,
        qr/idx_threads_category_activity_visible_locked/msx,
        'and the visible threads come from the covering category index'
    );
}
like(
    GPForum::Test::PostgresHarness::plan_without_seqscan(
        $dbh, $threads->category_threads_resultset( $viewer{author} )
    ),
    qr/idx_threads_deleted_category_activity/msx,
    'the author\'s own deleted threads come from the deleted-thread index'
);

# The profile lists visible and locked threads; its index was built for
# visible only, so the query walked the site-wide activity index instead.
my $profile =
  GPForum::Service::Identity::ProfileReader->new( schema => $schema )
  ->public_threads_resultset( $author_id, { fetch_rows => 11 } );
my $profile_plan =
  GPForum::Test::PostgresHarness::plan_without_seqscan( $dbh, $profile );
like(
    $profile_plan,
    qr/idx_threads_author_public_activity/msx,
    'the profile thread list reads the author index'
) or diag $profile_plan;
unlike(
    $profile_plan,
    qr/idx_threads_public_activity\b/msx,
    'and no longer walks the site-wide activity index'
);

$schema->storage->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _listed {
    my ( $reader, $request ) = @_;

    my $page =
      $reader->list_category_threads( { %{$request}, limit => 50 } );

    return
      scalar grep { $_->get_column('thread_id') eq $thread_id }
      @{ $page->{items} };
}

1;
