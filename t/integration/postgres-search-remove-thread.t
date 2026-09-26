# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Search::Indexer;
use GPForum::Test::LongThread;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $BATCH   => 5;
const my $POSTS   => 12;
const my $BATCHES => 3;

# Advisory locks held, and how many of them are post documents' locks keyed
# as Indexer::_lock_document keys them. A bigint lock shows its high half in
# classid and its low half in objid, with objsubid 1.
const my $HELD_SQL => join q{ },
  q{SELECT count(*), count(document.lock_key) FROM pg_locks l},
  q{LEFT JOIN (SELECT hashtextextended('search_document:post:' || post_id,},
  q{0) AS lock_key FROM posts WHERE thread_id = ?) document},
  q{ON l.classid::bigint = ((document.lock_key >> 32) & 4294967295)},
  q{AND l.objid::bigint = (document.lock_key & 4294967295)},
  q{AND l.objsubid = 1},
  q{WHERE l.locktype = 'advisory' AND l.pid = pg_backend_pid()};

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the thread removal test';
}

# A hidden thread leaves the index a batch of posts at a time. The removal
# was one transaction taking an advisory lock per post, and PostgreSQL's
# shared lock table holds max_locks_per_transaction for each backend: a
# thread of several thousand posts failed to leave, retried until it was
# dead-lettered, and its posts stayed searchable. Here a thread of twelve
# posts, batches of five: no transaction holds more than five of those locks,
# and nothing of the thread is left.
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
my $prepared = GPForum::Test::PostgresHarness::prepare_database();
is( $prepared->{migrate}, 0, 'migrations apply' );
is( $prepared->{seed},    0, 'the seed loads' );

my $schema  = GPForum::Test::PostgresHarness::connect_schema();
my $dbh     = $schema->storage->dbh;
my $indexer = GPForum::Service::Search::Indexer->new(
    rebuild_batch_size => $BATCH,
    schema             => $schema,
);

my ( $thread, $other ) = @{
    $dbh->selectcol_arrayref(
            q{SELECT thread_id FROM threads WHERE deleted_at IS NULL}
          . q{ AND moderation_state = 'visible' ORDER BY thread_id LIMIT 2}
    )
};
GPForum::Test::LongThread::grow( $dbh, $thread, $POSTS );
is( _count( 'SELECT count(*) FROM posts WHERE thread_id = ?', $thread ),
    $POSTS, "the thread has $POSTS posts" );

for my $id ( $thread, $other ) {
    $indexer->index_thread($id);
    $indexer->index_thread_posts($id);
}
is( _documents($thread), 1 + $POSTS, 'it is indexed with all of them' );
my $others = _documents($other);
ok( $others, 'and so is another thread' );

$dbh->do( q{UPDATE threads SET moderation_state = 'hidden' WHERE thread_id = ?},
    undef, $thread );
my $removal = _probe_locks( $thread, sub { $indexer->remove_thread($thread) } );

is(
    $removal->{transactions},
    1 + $BATCHES,
    'the thread in a transaction of its own, then one per batch of posts'
);
is_deeply(
    [ map { $_->[0] } @{ $removal->{held} } ],
    [ 1, $BATCH, $BATCH, $POSTS - 2 * $BATCH ],
    q{no transaction holds more than a batch's advisory locks}
);
is_deeply(
    [ map { $_->[1] } @{ $removal->{held} } ],
    [ 0, $BATCH, $BATCH, $POSTS - 2 * $BATCH ],
    'each one the lock a single post document is written under'
);
is( $removal->{result}{posts_removed},
    $POSTS, 'every post document of the thread is counted' );
is( _documents($thread), 0,
    'and no document of the thread or its posts is left' );
is( _documents($other), $others, 'another thread keeps its documents' );

my $again = $indexer->remove_thread($thread);
is_deeply(
    [ @{$again}{qw(deleted posts_removed)} ],
    [ 0, 0 ],
    'removing it again finds nothing left to delete'
);

$schema->storage->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

# The work's transactions, and the advisory locks held as each delete from
# search_documents is prepared: by then its transaction has taken every lock
# it will take. DBIx::Class prepares every statement through prepare_cached,
# which calls prepare itself on a miss, so only the first is watched.
sub _probe_locks {
    my ( $thread_id, $work ) = @_;

    my @held;
    my $transactions = 0;
    my $count_locks  = sub {
        my ( undef, $sql ) = @_;
        return if $sql !~ /\A \s* DELETE \s+ FROM \s+ search_documents/imsx;

        push @held, [ $dbh->selectrow_array( $HELD_SQL, undef, $thread_id ) ];

        return;
    };
    $dbh->{Callbacks} = {
        begin_work     => sub { $transactions++; return; },
        prepare_cached => $count_locks,
    };
    my $result = $work->();
    delete $dbh->{Callbacks};

    return { held => \@held, result => $result, transactions => $transactions };
}

sub _documents {
    my ($thread_id) = @_;

    return _count(
        q{SELECT count(*) FROM search_documents WHERE entity_id = ?}
          . q{ OR entity_id IN (SELECT post_id FROM posts WHERE thread_id = ?)},
        $thread_id, $thread_id
    );
}

sub _count {
    my ( $sql, @binds ) = @_;

    return scalar $dbh->selectrow_array( $sql, undef, @binds );
}

1;
