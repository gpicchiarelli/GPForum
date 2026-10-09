# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use DBIx::Class::ResultSet;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::CommunitySearch;
use GPForum::Test::ForumReadResultSet;
use GPForum::Test::ForumReadSearch;
use GPForum::Test::ModerationSearch;
use GPForum::Test::NotificationSearch;
use GPForum::Test::OutboxSearch;
use GPForum::Test::ProjectionGenerationSearch;
use GPForum::Test::PurgeResultSet;
use GPForum::Test::Row;
use GPForum::Test::SearchResult;
use GPForum::Test::SearchSearch;

our $VERSION = '0.001';

# What a fake search returns answers the DBIx::Class resultset surface lib/
# reads -- all, count, single, first, next, reset, get_column, search -- with
# DBIx::Class's semantics. lib/ asked ->can('all') or ->can('rows') in 33
# places because some of these doubles had only rows.
const my @DBIC_SEARCH_METHODS =>
  qw(all count first get_column next reset search search_rs single);
const my @SEARCH_DOUBLES => qw(
  GPForum::Test::CommunitySearch
  GPForum::Test::ForumReadSearch
  GPForum::Test::ModerationSearch
  GPForum::Test::NotificationSearch
  GPForum::Test::OutboxSearch
  GPForum::Test::ProjectionGenerationSearch
  GPForum::Test::PurgeResultSet
  GPForum::Test::SearchSearch
);
const my $NEWEST_POSITION => 3;
const my $TOTAL           => 6;

subtest 'every shared search double answers the resultset methods' => sub {
    for my $class (@SEARCH_DOUBLES) {
        my @missing = grep { !$class->can($_) } @DBIC_SEARCH_METHODS;
        is_deeply( \@missing, [], "$class answers them all" );
        my @rows = $class->new( rows => [ { id => 1 }, { id => 2 } ] )->all;
        is( scalar @rows, 2, "$class all returns the rows" );
    }
};

subtest q{no search double answers a name DBIx::Class's resultset lacks} =>
  sub {
    ok( !DBIx::Class::ResultSet->can('items'), 'DBIx::Class has no items' );
    my @answering = grep { $_->can('items') } @SEARCH_DOUBLES;
    is_deeply( \@answering, [],
        'and no double has one, so all is the only list' );
  };

subtest 'single is one row, undef, or the first with a warning' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };

    is( GPForum::Test::SearchResult->new( rows => [] )->single,
        undef, 'no row is undef' );
    is(
        GPForum::Test::SearchResult->new( rows => [ { id => 1 } ] )
          ->single->{id},
        1,
        'one row is that row'
    );
    is( scalar @warnings, 0, 'neither warns' );

    my $first =
      GPForum::Test::SearchResult->new( rows => [ { id => 1 }, { id => 2 } ] )
      ->single;
    is( $first->{id},     1, 'several rows give the first' );
    is( scalar @warnings, 1, 'and one warning' );
    like(
        $warnings[0] // q{},
        qr/\A Query [ ] returned [ ] more [ ] than [ ] one [ ] row/msx,
        'in the words DBIx::Class uses'
    );

    my $search =
      GPForum::Test::SearchResult->new( rows => [ { id => 1 }, { id => 2 } ] );
    is( $search->single( { id => 2 } )->{id}, 2, 'a condition narrows it' );
    my $error = q{};
    try {
        $search->single( { id => 2 }, { rows => 1 } );
    }
    catch ($caught) {
        $error = "$caught";
    };
    like(
        $error,
        qr/\A single[(][)] [ ] only [ ] takes [ ] search [ ] conditions/msx,
        'attributes are refused, as DBIx::Class refuses them'
    );
};

subtest 'the cursor walks the rows and starts again' => sub {
    my $search =
      GPForum::Test::SearchResult->new( rows => [ { id => 1 }, { id => 2 } ] );

    is( $search->next->{id},  1,     'next gives the first row' );
    is( $search->next->{id},  2,     'then the second' );
    is( $search->next,        undef, 'then undef' );
    is( $search->first->{id}, 1,     'first starts again' );
    $search->reset;
    is( $search->next->{id}, 1, 'and so does reset' );
    is( $search->count,      2, 'count is every row' );
};

subtest 'get_column reads one column, with SQL aggregates' => sub {
    my $search = GPForum::Test::SearchResult->new(
        rows => [
            { position => 1 },
            GPForum::Test::Row->new( data => { position => $NEWEST_POSITION } ),
            { position => undef },
            { position => 2 },
        ]
    );
    my $column = $search->get_column('me.position');

    is_deeply(
        [ $column->all ],
        [ 1, $NEWEST_POSITION, undef, 2 ],
        'all is every value, hash or row object'
    );
    is( $column->max, $NEWEST_POSITION, 'max skips NULL' );
    is( $column->min, 1,                'so does min' );
    is( $column->sum, $TOTAL,           'and sum' );
    is( $column->func('COUNT'),
        $NEWEST_POSITION, 'COUNT is the values not NULL' );
    ok( !$column->can('count'),
        'and, as on DBIx::Class::ResultSetColumn, there is no count method' );
    is( $column->func('MAX'), $NEWEST_POSITION, 'func names an aggregate' );
    is( $column->first,       1,                'first is the first value' );

    my $empty = GPForum::Test::SearchResult->new->get_column('position');
    is( $empty->max,           undef, 'MAX over no row is NULL' );
    is( $empty->sum,           undef, 'and so is SUM' );
    is( $empty->func('COUNT'), 0,     'COUNT over no row is 0' );
};

subtest 'a search of a search narrows, orders and windows it' => sub {
    my $search = GPForum::Test::ModerationSearch->new(
        rows => [
            { id => 1, status => 'open',   position => 2 },
            { id => 2, status => 'closed', position => 1 },
            {
                id       => $NEWEST_POSITION,
                status   => 'open',
                position => $NEWEST_POSITION
            },
        ]
    );
    my $narrowed = $search->search_rs( { status => 'open' },
        { order_by => { -desc => 'position' }, rows => 1 } );

    isa_ok( $narrowed, 'GPForum::Test::ModerationSearch' );
    is_deeply( [ map { $_->{id} } $narrowed->all ],
        [$NEWEST_POSITION], 'the newest open row alone' );
};

subtest 'a reader asking for the newest row gets it' => sub {
    my $posts = GPForum::Test::ForumReadResultSet->new(
        rows => [
            { post_id => 'post-1', position => 1 },
            { post_id => 'post-3', position => $NEWEST_POSITION },
            { post_id => 'post-2', position => 2 },
        ]
    );
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };

    my $latest = $posts->search_rs( {},
        { order_by => [ { -desc => 'position' } ], rows => 1 } )->single;

    is( $latest->{post_id}, 'post-3',
        'order_by and rows apply whatever order the test listed' );
    is( scalar @warnings, 0, 'and rows => 1 leaves single one row' );
};

done_testing();

1;
