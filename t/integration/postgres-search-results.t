# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::Viewer;
use GPForum::Service::Search::Indexer;
use GPForum::Service::Search::PermissionEngine;
use GPForum::Service::Search::Searcher;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the search results test';
}

# What search returns, on PostgreSQL (quality program 5.2). The unit double
# matches every document whatever the query, so ranking, the AND of the
# words, the tolerance for typos and the autocomplete prefix had no
# behavioural coverage at all. Three threads are given words of their own
# and indexed as the application indexes them.
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
my $prepared = GPForum::Test::PostgresHarness::prepare_database();
is( $prepared->{migrate}, 0, 'migrations apply' );
is( $prepared->{seed},    0, 'the seed loads' );

my $schema  = GPForum::Test::PostgresHarness::connect_schema();
my $dbh     = $schema->storage->dbh;
my $indexer = GPForum::Service::Search::Indexer->new( schema => $schema );

my ( $vacuum, $bodies, $zymurgy ) = @{
    $dbh->selectcol_arrayref(
            q{SELECT thread_id FROM threads WHERE deleted_at IS NULL}
          . q{ AND visibility = 'public' AND moderation_state = 'visible'}
          . q{ ORDER BY thread_id LIMIT 3}
    )
};
_retitle( $vacuum,  'Tuning postgres vacuum' );
_retitle( $zymurgy, 'Zymurgy basics' );
my ($reply) = $dbh->selectrow_array(
    q{SELECT post_id FROM posts WHERE thread_id = ? AND position > 1}
      . q{ ORDER BY position LIMIT 1},
    undef, $bodies
);
$dbh->do(
    q{UPDATE post_bodies SET body_source = ?, body_rendered_safe = ?}
      . q{ WHERE body_id = (SELECT current_body_id FROM posts WHERE post_id = ?)},
    undef, ('An aside on zymurgy and the brewing of it') x 2, $reply
);
$indexer->index_post($reply);

my $searcher = GPForum::Service::Search::Searcher->new(
    permission_engine =>
      GPForum::Service::Search::PermissionEngine->new( schema => $schema ),
    schema => $schema,
);
my $anonymous = { viewer => GPForum::Service::Forum::Viewer->anonymous };

is_deeply( [ _threads_of( _search('vacuum') ) ],
    [$vacuum], 'a word in one title finds that thread and its posts only' );
is_deeply( [ _threads_of( _search('postgres vacuum') ) ],
    [$vacuum], 'two words find what holds both' );

# The fuzzy arm compares the whole query with each title, so a title that
# shares one word of two is found too -- by design (8.9), and ranked by its
# similarity. Nothing else is.
is_deeply(
    [ _threads_of( _search('postgres zymurgy') ) ],
    [ sort $vacuum, $zymurgy ],
    'two words that no document holds together find the titles close to them'
);
is_deeply( [ _threads_of( _search('vacum') ) ],
    [$vacuum], 'a typo still finds the title, by its trigrams' );

my @zymurgy = _search('zymurgy');
is( $zymurgy[0]{entity_id}, $zymurgy,
    'a title match ranks above a body match' );
ok( ( grep { $_->{entity_id} eq $reply } @zymurgy ),
    'and the body match is found' );
like( ( grep { $_->{entity_id} eq $reply } @zymurgy )[0]{snippet} // q{},
    qr/zymurgy/msx, 'with the word in its snippet' );

is_deeply( [ _search('unfindableword') ], [], 'no match finds nothing' );

is_deeply(
    [
        map { $_->{entity_id} } @{
            $searcher->autocomplete(
                $anonymous, 'tuning pos', { limit => 10 }
            )
        }
    ],
    [$vacuum],
    'autocomplete completes a title from its first letters'
);

$schema->storage->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _retitle {
    my ( $thread_id, $title ) = @_;

    $dbh->do( 'UPDATE threads SET title = ? WHERE thread_id = ?',
        undef, $title, $thread_id );
    $indexer->index_thread($thread_id);
    $indexer->index_thread_posts($thread_id);

    return;
}

sub _search {
    my ($query) = @_;

    return @{ $searcher->search( $anonymous, $query, { limit => 50 } ) };
}

# The distinct threads the results belong to: a thread's own document, or
# its posts'.
sub _threads_of {
    my (@results) = @_;

    my %thread;
    for my $result (@results) {
        my $id =
            $result->{entity_type} eq 'thread'
          ? $result->{entity_id}
          : scalar $dbh->selectrow_array(
            'SELECT thread_id FROM posts WHERE post_id = ?',
            undef, $result->{entity_id} );
        $thread{$id} = 1;
    }

    return sort keys %thread;
}

1;
