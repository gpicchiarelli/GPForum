# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Search::Indexer;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the search rebuild test';
}

# ADR 0110's search rebuild on PostgreSQL: the projection is rebuilt from
# the canonical rows -- locked threads included, as the document builder
# indexes them -- documents whose source is deleted or hidden are removed,
# and a second run changes nothing.
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
my $prepared = GPForum::Test::PostgresHarness::prepare_database();
is( $prepared->{migrate}, 0, 'migrations apply' );
is( $prepared->{seed},    0, 'the seed loads' );

my $schema  = GPForum::Test::PostgresHarness::connect_schema();
my $dbh     = $schema->storage->dbh;
my $indexer = GPForum::Service::Search::Indexer->new( schema => $schema );

my $first = $indexer->rebuild( { entity_type => 'all' } );
ok( $first->{ok}, 'a rebuild succeeds' );
is(
    _documents(),
    _live('thread') + _live('post'),
    'and leaves one document per live thread and post'
);

my @threads = @{
    $dbh->selectcol_arrayref(
            q{SELECT thread_id FROM threads WHERE deleted_at IS NULL}
          . q{ AND moderation_state = 'visible' ORDER BY thread_id LIMIT 3}
    )
};
my ( $locked, $deleted, $hidden ) = @threads;
$dbh->do( q{UPDATE threads SET moderation_state = 'locked' WHERE thread_id = ?},
    undef, $locked );
$dbh->do( q{DELETE FROM search_documents WHERE entity_id = ?}, undef, $locked );
$dbh->do( q{UPDATE threads SET deleted_at = now() WHERE thread_id = ?},
    undef, $deleted );
$dbh->do( q{UPDATE threads SET moderation_state = 'hidden' WHERE thread_id = ?},
    undef, $hidden );

my $again = $indexer->rebuild( { entity_type => 'all' } );
ok( _document( 'thread',  $locked ),  'a locked thread is indexed' );
ok( !_document( 'thread', $deleted ), 'a deleted thread is removed' );
ok( !_document( 'thread', $hidden ),  'a hidden thread is removed' );
is(
    scalar $dbh->selectrow_array(
        q{SELECT count(*) FROM search_documents d JOIN posts p}
          . q{ ON p.post_id = d.entity_id WHERE d.entity_type = 'post'}
          . q{ AND p.thread_id IN (?, ?)},
        undef,
        $deleted,
        $hidden
    ),
    0,
    'and so are the posts in them'
);
cmp_ok( $again->{pruned}, q{>=}, 2, 'the rebuild counts what it removed' );
is(
    _documents(),
    _live('thread') + _live('post'),
    'one document per live thread and post, still'
);

my $third = $indexer->rebuild( { entity_type => 'all' } );
is_deeply(
    [ @{$third}{qw(indexed pruned)} ],
    [ 0, 0 ],
    'a second rebuild changes nothing'
);

# Rebuilding threads alone still removes the posts of a thread that died:
# they held its title and would stay searchable.
my ($dying) = $dbh->selectrow_array(
        q{SELECT t.thread_id FROM threads t JOIN search_documents d}
      . q{ ON d.entity_type = 'post' JOIN posts p ON p.post_id = d.entity_id}
      . q{ AND p.thread_id = t.thread_id WHERE t.deleted_at IS NULL LIMIT 1} );
$dbh->do( q{UPDATE threads SET deleted_at = now() WHERE thread_id = ?},
    undef, $dying );
$indexer->rebuild( { entity_type => 'thread' } );
is(
    scalar $dbh->selectrow_array(
        q{SELECT count(*) FROM search_documents d JOIN posts p}
          . q{ ON p.post_id = d.entity_id WHERE d.entity_type = 'post'}
          . q{ AND p.thread_id = ?},
        undef,
        $dying
    ),
    0,
    'a thread rebuild removes the posts of a dead thread too'
);

$dbh->do(
        q{INSERT INTO outbox_messages (outbox_id, event_id, queue, job_type,}
      . q{ idempotency_key, status) VALUES (gen_random_uuid(),}
      . q{ gen_random_uuid(), 'events', 'domain_event.dispatch',}
      . q{ 'lag-probe', 'pending')} );
my $lag = $indexer->observe_lag;
is(
    $lag->{pending},
    scalar $dbh->selectrow_array(
            q{SELECT count(*) FROM outbox_messages}
          . q{ WHERE status IN ('pending', 'running', 'failed')}
    ),
    'the lag counts the outbox messages not yet delivered'
);
is(
    $lag->{status},
    $lag->{pending} ? 'behind' : 'current',
    'and says whether search is behind'
);

$schema->storage->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _documents {
    return
      scalar $dbh->selectrow_array('SELECT count(*) FROM search_documents');
}

sub _document {
    my ( $type, $id ) = @_;

    return scalar $dbh->selectrow_array(
        'SELECT count(*) FROM search_documents'
          . ' WHERE entity_type = ? AND entity_id = ?',
        undef, $type, $id
    );
}

sub _live {
    my ($type) = @_;

    my %sql = (
        post => q{SELECT count(*) FROM posts p JOIN threads t}
          . q{ ON t.thread_id = p.thread_id WHERE p.deleted_at IS NULL}
          . q{ AND p.moderation_state = 'visible' AND t.deleted_at IS NULL}
          . q{ AND t.moderation_state IN ('visible', 'locked')},
        thread => q{SELECT count(*) FROM threads WHERE deleted_at IS NULL}
          . q{ AND moderation_state IN ('visible', 'locked')},
    );
    return scalar $dbh->selectrow_array( $sql{$type} );
}

1;
