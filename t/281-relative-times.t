# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::CommandIdempotency;
use GPForum::Test::FixedClock;
use GPForum::Test::ForumWebServices;

our $VERSION = '0.001';

const my $HTTP_OK => 200;

# Every fixture timestamp is 2026-05-23T12:00:00Z; NOON is that epoch.
const my $STORED => '2026-05-23T12:00:00Z';
const my $NOON   => 1_779_537_600;
const my $MINUTE => 60;
const my $HOUR   => 3_600;
const my $WEEK   => 604_800;
const my $A_FEW  => 3;

const my $TIME       => qq{time[datetime="$STORED"]};
const my $UTC_TITLE  => '2026-05-23 12:00 UTC';
const my $ROME_TITLE => '2026-05-23 14:00 CEST';
const my $IT_TITLE   => '23/05/2026 12:00 UTC';
const my $RELATIVE =>
  qq{<time datetime="$STORED" title="$UTC_TITLE">3 minutes ago</time>};

my $test = Test::Mojo->new('GPForum');
_install_forum_fakes($test);
_install_test_routes($test);

my $clock = GPForum::Test::FixedClock->new( epoch => $NOON + $A_FEW * $MINUTE );
my $formats = $test->app->i18n_service->formats;
$formats->clock($clock);

# An anonymous page may be served from the public page cache, and kept by a
# browser or proxy for max-age and stale-while-revalidate more. It shows the
# absolute time, in the forum's zone, with nothing that depends on the clock.
$test->get_ok('/c/category-1');
$test->status_is($HTTP_OK);
$test->header_is( 'X-GPForum-Cache' => 'miss' );
$test->element_exists(qq{$TIME\[title="$UTC_TITLE"]});
$test->text_is( $TIME => $UTC_TITLE );
$test->content_unlike( qr/\b ago \b/msx,
    'an anonymous page carries no relative phrase' );
my $first_render = _clock_free_body($test);

# Nothing on the page depends on the clock: rendered again an hour later,
# once the cached copy is gone, it is the same page, so a copy kept anywhere
# meanwhile is not stale. (Its CSRF tokens are minted per render, and are
# set aside for the comparison.)
$clock->epoch( $NOON + $HOUR );
$test->app->gp_local_cache->clear;
$test->get_ok('/c/category-1');
$test->header_is( 'X-GPForum-Cache' => 'miss' );
is( _clock_free_body($test), $first_render,
    'an hour later the anonymous page renders the same' );

$clock->epoch( $NOON + $A_FEW * $MINUTE );
$test->get_ok( '/c/category-1' => { 'Accept-Language' => 'it' } );
$test->text_is( $TIME => $IT_TITLE );
$test->content_unlike( qr/\b fa \b/msx, 'nor does an anonymous Italian page' );

$test->get_ok('/search?q=welcome');
$test->status_is($HTTP_OK);
$test->text_is( $TIME => $UTC_TITLE );

# A member whose session has run out is signed out at the door, but the rest
# of the request still holds their preferences. The page it renders is
# anonymous and goes into the cache every visitor shares -- keyed by locale
# and theme, not zone -- so it is in the forum's zone, never in theirs.
$test->app->gp_local_cache->clear;
$test->get_ok('/__test/session/user-1?zone=Europe/Rome&expired=1');
$test->get_ok('/c/category-1');
$test->header_is( 'X-GPForum-Cache' => 'miss' );
$test->text_is( $TIME => $UTC_TITLE, 'a lapsed member gets the forum zone' );
$test->element_exists( qq{$TIME\[title="$UTC_TITLE"]}, 'in title as well' );
$test->reset_session;
$test->get_ok('/c/category-1');
$test->header_is( 'X-GPForum-Cache' => 'hit' );
$test->text_is(
    $TIME => $UTC_TITLE,
    'so the next visitor is not served Rome time from the cache'
);

# A signed-in page is rendered for its reader and never cached: it says how
# long ago, and keeps the absolute time in title.
$test->get_ok('/__test/session/user-1');
$test->get_ok('/c/category-1');
$test->status_is($HTTP_OK);
$test->header_is( 'X-GPForum-Cache' => undef );
$test->element_exists(qq{$TIME\[title="$UTC_TITLE"]});
$test->text_is( $TIME => '3 minutes ago' );

$clock->epoch( $NOON + $MINUTE - 1 );
$test->get_ok('/c/category-1');
$test->text_is( $TIME => 'just now' );

$clock->epoch( $NOON + $HOUR );
$test->get_ok('/c/category-1');
$test->text_is(
    $TIME => 'an hour ago',
    'the next render reads the clock again'
);

# A week on, the phrase gives way to the date; title keeps the full time.
$clock->epoch( $NOON + $WEEK );
$test->get_ok('/c/category-1');
$test->text_is( $TIME => '2026-05-23' );
$test->element_exists(qq{$TIME\[title="$UTC_TITLE"]});

# In the reader's locale, with its plural forms.
$clock->epoch( $NOON + $A_FEW * $MINUTE );
$test->get_ok( '/c/category-1' => { 'Accept-Language' => 'it' } );
$test->text_is( $TIME => '3 minuti fa' );
$test->element_exists(qq{$TIME\[title="$IT_TITLE"]});
$clock->epoch( $NOON + $MINUTE );
$test->get_ok( '/c/category-1' => { 'Accept-Language' => 'it' } );
$test->text_is( $TIME => 'un minuto fa' );

# And in the member's own zone: the phrase is elapsed time, the title is
# Rome time and says so.
$clock->epoch( $NOON + $A_FEW * $MINUTE );
$test->get_ok('/__test/session/user-1?zone=Europe/Rome');
$test->get_ok('/c/category-1');
$test->text_is( $TIME => '3 minutes ago' );
$test->element_exists(qq{$TIME\[title="$ROME_TITLE"]});

# The other forum pages and the notification surface, signed in.
$test->get_ok('/__test/session/user-1');
$test->get_ok('/bookmarks');
$test->status_is($HTTP_OK);
$test->content_like(qr{Saved: [ ] \Q$RELATIVE\E}msx);
$test->get_ok('/feed');
$test->status_is($HTTP_OK);
$test->content_like(qr{Added: \s* <time [^>]+>3 [ ] minutes [ ] ago</time>}msx);
$test->get_ok('/search?q=welcome');
$test->text_is( $TIME => '3 minutes ago' );
$test->get_ok('/notifications');
$test->status_is($HTTP_OK);
$test->content_like(
    qr{Received: \s* <time [^>]+>3 [ ] minutes [ ] ago</time>}msx);

# The partial on its own: no value shows the caller's placeholder, and a value
# the formatter cannot read is shown as it is, never as a made-up time.
# (An inline render ends with a newline of its own.)
$test->get_ok('/__test/timestamp');
$test->content_like(qr/\A Unknown \s* \z/msx);
$test->get_ok('/__test/timestamp?at=yesterday-ish');
$test->content_like(qr/\A yesterday-ish \s* \z/msx);
$test->get_ok( '/__test/timestamp?at=' . $STORED );
$test->content_like(qr{\A \Q$RELATIVE\E \s* \z}msx);

done_testing();

sub _clock_free_body {
    my ($test_object) = @_;

    my $body = $test_object->tx->res->body;
    $body =~ s/name="csrf_token" [ ] type="hidden" [ ] value="[^"]*"//gmsx;

    return $body;
}

sub _install_forum_fakes {
    my ($test_object) = @_;

    my $services = GPForum::Test::ForumWebServices->new;
    for my $helper (
        qw(
        gp_category_reader gp_thread_reader gp_thread_detail_reader
        gp_post_reader gp_thread_read_state gp_mention_store
        gp_mention_reader gp_bookmark_store gp_subscription_store
        gp_notification_dispatcher gp_search_service gp_rate_limiter
        gp_suspension_store gp_attachment_store
        )
      )
    {
        $test_object->app->helper( $helper => sub { return $services; } );
    }
    $test_object->app->helper(
        gp_feed_reader => sub {
            return GPForum::Test::ForumWebServices->new( mode => 'feed' );
        }
    );
    $test_object->app->helper(
        gp_command_idempotency => sub {
            return GPForum::Test::CommandIdempotency->new;
        }
    );

    return;
}

sub _install_test_routes {
    my ($test_object) = @_;

    my $routes = $test_object->app->routes;
    $routes->get('/__test/session/:user_id')->to(
        cb => sub {
            my ($controller) = @_;

            $controller->session( user_id => $controller->param('user_id') );
            $controller->session(
                preferred_timezone => $controller->param('zone') );

            # Long past: the next request's session guard signs it out.
            if ( $controller->param('expired') ) {
                $controller->session( session_expires_at_epoch => 1 );
            }
            return $controller->render( json => { ok => 1 } );
        }
    );
    $routes->get('/__test/timestamp')->to(
        cb => sub {
            my ($controller) = @_;

            $controller->session( user_id => 'user-1' );
            return $controller->render(
                inline => q{<%= include 'components/timestamp', }
                  . q{at => param('at'), missing => 'Unknown' %>}, );
        }
    );

    return;
}

1;
