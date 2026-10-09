# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Mojo::Server::Daemon;
use Mojo::Server::Prefork;
use Mojo::Util qw(encode md5_sum);
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::ForumWebServices;
use GPForum::Web::Warmup;

our $VERSION = '0.001';

const my $HTTP_OK => 200;
const my @PAGES => (
    q{/},            '/categories', '/login', '/register',
    '/c/category-1', '/t/thread-1',
);
const my $WARMED => qr{\A warmed[ ]6[ ]pages[ ]before[ ]forking}msx;
const my $TIMED =>
  qr{[ ]in[ ][[:digit:]]+[ ]ms:[ ]/[ ]200,[ ]/categories[ ]200}msx;

# Before a pre-forking server forks, the main pages are rendered once, so
# the workers inherit compiled templates and filled memos.
my $test = Test::Mojo->new('GPForum');
my $app  = $test->app;
_install_forum_fakes($test);

my @warming;
$app->hook(
    before_dispatch => sub ($controller) {
        push @warming, $controller->stash('gpforum.warming') ? 1 : 0;
    }
);

my $report = GPForum::Web::Warmup->new( application => $app )->run;
is_deeply( [ map { $_->{path} } @{ $report->{pages} } ],
    \@PAGES,
    'the pages that need no row, then the newest thread and its category' );
is_deeply(
    [ map { $_->{status} } @{ $report->{pages} } ],
    [ ($HTTP_OK) x @PAGES ],
    'every page rendered'
);
cmp_ok( $report->{milliseconds}, '>', 0, 'the report says how long it took' );
is_deeply( \@warming, [ (1) x @PAGES ], 'each request was marked as warming' );
ok(
    !exists $app->defaults->{'gpforum.warming'},
    'and the mark is gone once the pages are warm'
);

for my $template (
    qw(layouts/default.html.ep forum/thread.html.ep forum/_posts.html.ep))
{
    my $compiled =
      $app->renderer->cache->get( md5_sum encode 'UTF-8', $template );
    ok( $compiled && $compiled->compiled, "$template is compiled" );
}

like(
    GPForum::Web::Warmup->describe($report),
    qr{$WARMED $TIMED}msx,
    'the log line names the pages and their statuses'
);

@warming = ();
$test->get_ok(q{/})->status_is($HTTP_OK);
is_deeply( \@warming, [0], 'a request served afterwards is not warming' );

# The hook runs for a pre-forking server only: a single process has no
# workers to warm for.
my @logged;
$app->log->on(
    message => sub ( $log, $level, @lines ) {
        if ( $level eq 'info' ) {
            push @logged, @lines;
        }
    }
);
@warming = ();
$app->plugins->emit_hook(
    before_server_start => Mojo::Server::Daemon->new,
    $app
);
is_deeply( \@warming, [], 'a daemon does not warm' );
$app->plugins->emit_hook(
    before_server_start => Mojo::Server::Prefork->new,
    $app
);
is_deeply( \@warming, [ (1) x @PAGES ], 'a pre-forking server warms' );
ok( ( grep { $_ =~ $WARMED } @logged ), 'and logs what it warmed' );

done_testing();

sub _install_forum_fakes ($test_object) {
    my $services = GPForum::Test::ForumWebServices->new;
    for my $helper (
        qw(
        gp_category_reader gp_thread_reader gp_thread_detail_reader
        gp_post_reader gp_thread_read_state gp_mention_store
        gp_mention_reader gp_bookmark_store gp_subscription_store
        gp_notification_dispatcher gp_search_service gp_rate_limiter
        gp_suspension_store gp_attachment_store gp_home_page_reader
        )
      )
    {
        $test_object->app->helper( $helper => sub { return $services; } );
    }

    return;
}

1;
