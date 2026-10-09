# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use English qw(-no_match_vars);
use Test::More;

use lib 'lib';

use GPForum::Infrastructure::PreparedQuery;
use GPForum::Schema;

our $VERSION = '0.001';

# No statement runs: the schema is connected to a port nothing listens on,
# so a lookup that reached the database would die on the connection.
my $schema =
  GPForum::Schema->connect('dbi:Pg:dbname=gpforum_no_database;port=1');
my $prepared = GPForum::Infrastructure::PreparedQuery->new;
my $threads  = $schema->resultset('Thread');

sub lookup ($thread_id) {
    return $prepared->rows(
        schema    => $schema,
        shape     => 'guards:thread',
        source    => 'Thread',
        resultset => sub {
            return $threads->search_rs( { 'me.thread_id' => $thread_id } );
        },
        values => { 'me.thread_id' => $thread_id },
    );
}

# A value PostgreSQL would not read as a uuid, bound for a uuid column,
# sends no statement and finds nothing: /t/new is a 404, not a 500.
is_deeply( lookup('new'), [], 'a word bound for a uuid column finds nothing' );
is_deeply( lookup('018f1000-0000-7000-8000-0000000000ff-x'),
    [], 'as does a uuid with a tail' );

my $reached = eval { lookup('018f1000-0000-7000-8000-0000000000ff'); 1 };
like(
    $EVAL_ERROR,
    qr/connect|connection|refused|could not/imsx,
    'a uuid reaches the database (which is not there)'
);
ok( !$reached, 'and the statement was sent' );

# A statement built from a request without a value for a column does not
# serve a request that has one: that request runs its own resultset.
my $by_author = sub ($author) {
    return $prepared->rows(
        schema    => $schema,
        shape     => 'guards:author',
        source    => 'Thread',
        resultset => sub {
            return $threads->search_rs( { 'me.author_user_id' => $author } );
        },
        values => { 'me.author_user_id' => $author },
    );
};
my $with_null = eval { $by_author->(undef); 1 };
ok( !$with_null, 'the first request, with no author, builds IS NULL' );
my $fits = eval { $by_author->('018f1000-0000-7000-8000-0000000000ff'); 1 };
like(
    $EVAL_ERROR,
    qr/connect|connection|refused|could not/imsx,
    'the next, with an author, runs its own resultset'
);
ok( !$fits, 'rather than the kept statement' );

done_testing();

1;
