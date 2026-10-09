# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Digest::SHA   qw(sha256_hex);
use JSON::MaybeXS qw(decode_json);
use List::Util    qw(none);
use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Benchmark::SeedDataset qw(dataset_counts insert_dataset seed_id);
use GPForum::Command::HypnotoadBenchmark;
use GPForum::Command::PerformanceSeed;
use GPForum::Test::BindRecordingDbh;

our $VERSION = '0.001';

# The rows the performance seed writes, and the ids and routes the benchmarks
# take from it. The seed was rewritten from a hand-written statement per table
# into SeedDataset's table-driven rows, checked then against a dump of every
# row before and after; nothing kept the rows pinned once the dump was gone,
# and a changed timestamp, ranking or search vector would only show as
# benchmarks that quietly measure something else.

const my $USERS            => 3;
const my $CATEGORIES       => 2;
const my $THREADS          => 4;
const my $POSTS_PER_THREAD => 3;
const my $READ_THREADS     => 3;
const my $NOTIFICATIONS    => 3;
const my $POST_KEY         => 10_001;
const my $WRAPPED_POST_KEY => 70_000;
const my $CATEGORY_ROUTE   => '/c/018f1001-0001-7000-8000-000000000001';
const my $THREAD_ROUTE     => '/t/018f1004-0001-7000-8000-000000000001';

# [ kind, number, id ]: the family is the kind's, the number is in both the
# second group (modulo 65,536) and the last.
const my @SEED_IDS => (
    [ space    => 1,                 '018f1000-0001-7000-8000-000000000001' ],
    [ category => 1,                 '018f1001-0001-7000-8000-000000000001' ],
    [ user     => 3,                 '018f1002-0003-7000-8000-000000000003' ],
    [ thread   => 1,                 '018f1004-0001-7000-8000-000000000001' ],
    [ post     => $POST_KEY,         '018f1005-2711-7000-8000-000000002711' ],
    [ post     => $WRAPPED_POST_KEY, '018f1005-1170-7000-8000-000000011170' ],
    [ role     => 2,                 '018f100a-0002-7000-8000-000000000002' ],
    [ moderation_action => 1,        '018f1010-0001-7000-8000-000000000001' ],
);

# What a re-seed deletes first, children before parents.
const my @CLEARED => (
    q{DELETE FROM moderation_actions}
      . q{ WHERE moderation_action_id::text LIKE '018f1010-%'},
    q{DELETE FROM reports WHERE report_id::text LIKE '018f100f-%'},
    q{DELETE FROM notification_inbox}
      . q{ WHERE notification_id::text LIKE '018f1009-%'},
    q{DELETE FROM notifications WHERE notification_id::text LIKE '018f1009-%'},
    q{DELETE FROM user_feed_items WHERE user_id::text LIKE '018f1002-%'}
      . q{ OR item_id::text LIKE '018f1004-%'},
    q{DELETE FROM subscriptions WHERE subscription_id::text LIKE '018f100e-%'},
    q{DELETE FROM bookmarks WHERE bookmark_id::text LIKE '018f100d-%'},
    q{DELETE FROM user_read_marker_deltas}
      . q{ WHERE user_id::text LIKE '018f1002-%'}
      . q{ OR thread_id::text LIKE '018f1004-%'},
    q{DELETE FROM thread_read_state WHERE user_id::text LIKE '018f1002-%'}
      . q{ OR thread_id::text LIKE '018f1004-%'},
    q{DELETE FROM thread_counters WHERE thread_id::text LIKE '018f1004-%'},
    q{DELETE FROM search_documents WHERE space_id = ?},
    q{DELETE FROM post_revisions WHERE revision_id::text LIKE '018f1007-%'},
    q{DELETE FROM post_bodies WHERE body_id::text LIKE '018f1006-%'},
    q{DELETE FROM posts WHERE post_id::text LIKE '018f1005-%'},
    q{DELETE FROM threads WHERE thread_id::text LIKE '018f1004-%'},
    q{DELETE FROM category_stats WHERE category_id::text LIKE '018f1001-%'},
    q{DELETE FROM categories WHERE space_id = ?},
    q{DELETE FROM role_bindings WHERE binding_id::text LIKE '018f100c-%'},
    q{DELETE FROM sessions WHERE session_id::text LIKE '018f1003-%'},
    q{DELETE FROM users WHERE id::text LIKE '018f1002-%'},
    q{DELETE FROM spaces WHERE space_id = ?},
);

# The tables in the order the seed first writes them, parents first.
const my @WRITTEN => qw(
  spaces users roles permissions role_permissions role_bindings sessions
  categories threads posts post_bodies post_revisions
  posts_current thread_counters
  search_documents category_stats thread_read_state user_read_marker_deltas
  bookmarks subscriptions notifications notification_inbox user_feed_items
  reports moderation_actions
);

# Each table's rows for the seed of the numbers above, as a digest of every
# column and value it binds and the statement that binds them. A change made
# on purpose updates the digest; the test prints the rows it found.
const my %ROWS => (
    spaces =>
      '018ea4d52f86f41d1c8906ddab51390aad76b564a0daab2569854c597cde14b2',
    users => 'f5d530ccfd0233fff613a1f52dcbe1ad8fc0909a9aaf597bbe505538b4b99e1a',
    roles => 'a615a423ee88740147af9d53db06069b0c7cd5ca8fe0a9fe4f26f94490e815cd',
    permissions =>
      '7c850ee1e6d5e79e7dbe94c32cf1aa51fc4c312acc84c063b53537035eb0848d',
    role_permissions =>
      '0d77c6e875bb770d38672f3613e0c28228bf433b404417229c8d3706846e00c0',
    role_bindings =>
      '26b65d877f50d5e1659af152beb59f2f16f3643e5cdb98185377ee03abf7c4f3',
    sessions =>
      'f5cfc4de1e2b226935360a4312525a5cc83b8e279a5a27d260c77f53d96ca7ac',
    categories =>
      '8b8ceecf7fe30905ed161dc0534da74c4ec88b32870abe7e489f22331ec02db1',
    threads =>
      'ecb443d4228268f9d538b47c7c93f25c9e648bb011191ce69ad49a7998cfbfb8',
    posts => '096d66ae31a1aedfd2ab0530f33cdc7c3caa51f48a9bbeaa681954cea445003f',
    post_bodies =>
      'aa07a7471af29f1c77df44bf6ae0d32bfe40ef04a1463daa27d47cd5af365f0b',
    post_revisions =>
      'b378991c77f82402598e4bb69898b6d7fbf088cfee205070b33cc792f920d7d0',
    posts_current =>
      'f00dd47f3aeea79bf12c9ca9b66ad783f788f747428c8b50bf6f9f76574b2856',
    thread_counters =>
      '0f96090b4c91f11c3c62dfa86aecb5eb45de2744990ea3f44918992b49a9dc23',
    search_documents =>
      '5810dadc042e46db3b81a57a6034f5b11059985fc8024653a3ababa313675828',
    category_stats =>
      '7a2082f0539841f7346bc28776a68e16b92516969e016f169551ebbc59972c09',
    thread_read_state =>
      '5a4de0bdceb5eca66b231fdf99f05d5f91bbfa6129d07c06419ff29c8c036a56',
    user_read_marker_deltas =>
      '4be296c4ab0e53979be564021ff192f443afff70395245ce2ee669e088be68f4',
    bookmarks =>
      'd7005def3f449063f0822a1d2f99c1b625666aaf6b1c3d08b655f549a2939036',
    subscriptions =>
      '26a569541344bb5463596bf4b529547b9da4428b04b28135a41d0f70555c7b14',
    notifications =>
      'e07269d8b1f1ec0d46844be2efa91ed87d8c3795ec37a2d014141f0417dd4abe',
    notification_inbox =>
      '5245a4b9736548ec80013cd7d9906843f375b83679cd07200544c117df83f561',
    user_feed_items =>
      '1b44f5e0757098ef0ca3b4708bc135d71095f000f004609d042e323c87bd89a9',
    reports =>
      '5cc55cccd6e7ba973566e514f9ca35f4684d6f96b5575a2032bf527c1fc48cf8',
    moderation_actions =>
      '3571d175b249c7c841d349eba03f4d72f237bf166680056631841caedb955af8',
);

my $numbers = {
    users            => $USERS,
    categories       => $CATEGORIES,
    threads          => $THREADS,
    posts_per_thread => $POSTS_PER_THREAD,
};
my $counts = dataset_counts($numbers);

_test_seed_ids();
_test_dataset_counts();
_test_rows();
_test_dry_run_report();
_test_benchmark_routes();

done_testing();

sub _test_seed_ids {
    for my $case (@SEED_IDS) {
        my ( $kind, $number, $id ) = @{$case};
        is( seed_id( $kind, $number ), $id, "seed_id( $kind => $number )" );
    }
    throws_ok { seed_id( 'thraed', 1 ) } qr/thraed/msx,
      'a kind the seed has no family for is refused';

    return;
}

sub _test_dataset_counts {
    is_deeply(
        $counts,
        {
            users              => $USERS,
            categories         => $CATEGORIES,
            threads            => $THREADS,
            posts_per_thread   => $POSTS_PER_THREAD,
            posts              => $THREADS * $POSTS_PER_THREAD,
            sessions           => $USERS,
            roles              => 3,
            permissions        => 6,
            role_bindings      => $USERS,
            read_states        => $USERS * $READ_THREADS,
            bookmarks          => $USERS,
            subscriptions      => $USERS,
            notifications      => $USERS * $NOTIFICATIONS,
            feed_items         => $THREADS,
            reports            => $THREADS,
            moderation_actions => $USERS,
        },
        'a seed writes a row of each kind per user, thread or post it names'
    );
    is( dataset_counts( { %{$numbers}, threads => 1 } )->{reports},
        1, 'and no more reports than threads' );

    return;
}

sub _test_rows {
    my $dbh = GPForum::Test::BindRecordingDbh->new;
    insert_dataset( $dbh, { dataset => $counts } );
    my ( $deletes, $tables ) = _recorded( $dbh->statements );

    is_deeply( $deletes, \@CLEARED,
        'a re-seed first deletes the rows of its own id families and space' );
    is_deeply( [ map { $_->{table} } @{$tables} ],
        \@WRITTEN, 'then writes each table, parents before children' );

    for my $table ( @{$tables} ) {
        my $digest = sha256_hex(
            JSON::MaybeXS->new( canonical => 1 )->encode(
                { statements => $table->{statements}, rows => $table->{rows} }
            )
        );
        is(
            $digest,
            $ROWS{ $table->{table} },
            "$table->{table}: the rows the seed writes are unchanged"
        ) or diag explain $table;
    }

    return;
}

sub _test_dry_run_report {
    my $report = decode_json(
        _stdout(
            sub {
                GPForum::Command::PerformanceSeed->new->run( '--dry-run',
                    '--json' );
            }
        )
    );

    is_deeply(
        $report,
        {
            status  => 'dry-run',
            profile => 'small',
            dataset => dataset_counts(
                {
                    users            => 5,
                    categories       => 3,
                    threads          => 12,
                    posts_per_thread => 8,
                }
            ),
            routes => {
                home         => q{/},
                categories   => q{/categories},
                category     => $CATEGORY_ROUTE,
                thread       => $THREAD_ROUTE,
                search       => q{/search?q=performance},
                health       => q{/health},
                health_ready => q{/health/ready},
                metrics      => q{/metrics},
            },
        },
        'the small seed reports its dataset and the routes into it'
    );

    is(
        _stdout(
            sub {
                GPForum::Command::PerformanceSeed->new->run(
                    '--dry-run', '--users',
                    $USERS,      '--categories',
                    $CATEGORIES, '--threads',
                    $THREADS,    '--posts-per-thread',
                    $POSTS_PER_THREAD,
                );
            }
        ),
        join(
            q{},
            "performance_seed status=dry-run\n",
            "profile=custom\n",
            'users=3 categories=2 threads=4 posts=12 sessions=3',
            ' read_states=9 notifications=9 bookmarks=3 subscriptions=3',
            " reports=4 moderation_actions=3\n",
            "category_route=$CATEGORY_ROUTE\n",
            "thread_route=$THREAD_ROUTE\n",
            "search_route=/search?q=performance\n"
        ),
        'and its text names the same counts and routes'
    );

    return;
}

sub _test_benchmark_routes {
    my $report = decode_json(
        _stdout(
            sub {
                GPForum::Command::HypnotoadBenchmark->new->run( '--dry-run',
                    '--json' );
            }
        )
    );

    is_deeply(
        $report->{routes},
        [
            q{/},                     q{/categories},
            $CATEGORY_ROUTE,          $THREAD_ROUTE,
            q{/search?q=performance}, q{/search/autocomplete?q=per},
            q{/health/live},          q{/health/ready},
            q{/metrics},
        ],
        'the hypnotoad benchmark measures the seeded category and thread'
    );

    return;
}

# The DELETE statements in order, then each table the seed writes with its
# rows -- column => value, every value a string or undef -- and the
# statements that wrote them.
sub _recorded ($statements) {
    my ( @deletes, @tables, %table );
    for my $statement ( @{$statements} ) {
        my ( $sql, $binds ) = @{$statement}{qw(sql binds)};
        if ( $sql =~ /\A DELETE \s/msx ) {
            push @deletes, $sql;
            next;
        }
        my ( $name, @columns ) = _written($sql);
        if ( !$table{$name} ) {
            $table{$name} = { table => $name, statements => [], rows => [] };
            push @tables, $table{$name};
        }
        my $table = $table{$name};
        if ( none { $_ eq $sql } @{ $table->{statements} } ) {
            push @{ $table->{statements} }, $sql;
        }
        push @{ $table->{rows} },
          { map { $columns[$_] => _text( $binds->[$_] ) } 0 .. $#columns };
    }

    return ( \@deletes, \@tables );
}

sub _written ($sql) {
    if ( $sql =~ /\A INSERT \s+ INTO \s+ (\w+) \s+ [(] ([^)]+) [)]/msx ) {
        return ( $1, split /,\s*/msx, $2 );
    }

    if ( $sql =~ /\A UPDATE \s+ posts \s/msx ) {
        return ( 'posts_current',
            qw(current_body_id current_revision_id post_id) );
    }

    return BAIL_OUT("the seed sent a statement this test does not know: $sql");
}

sub _text ($value) {
    return defined $value ? "$value" : undef;
}

sub _stdout ($code) {
    my $stdout = q{};
    open my $handle, '>', \$stdout or BAIL_OUT('cannot capture STDOUT');
    {
        local *STDOUT = $handle;
        $code->();
    }
    close $handle or BAIL_OUT('cannot close the captured STDOUT');

    return $stdout;
}

1;
