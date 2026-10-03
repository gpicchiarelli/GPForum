# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::CommandIdempotency;
use GPForum::Test::ForumWebServices;

our $VERSION = '0.001';

const my $HTTP_OK => 200;
const my $POST    => 'article.post#post-post-1';
const my $WRITTEN => '2026-05-23T12:00:00Z';

# What a reader types into: these stood, thirteen forms deep, between a
# thread's title and its first post, which began below the first screen.
const my $FIELDS => 'textarea, select, input:not([type="hidden"])';

my $test = Test::Mojo->new('GPForum');
_install_forum_fakes($test);
_install_session_route($test);

# The thread page is the conversation. A signed-in author, who has every
# action there is, still finds nothing to fill in above the first post: each
# action that needs a field, or a second thought, waits in a sheet.
$test->get_ok('/__test/session/user-1');
$test->get_ok('/t/thread-1');
$test->status_is($HTTP_OK);

my $dom = $test->tx->res->dom;
is_deeply( _fields_outside_sheets($dom),
    ['reply-body'], 'the one field on the page is where a reply is written' );

# A post says who wrote it and when.
$test->element_exists(qq{$POST .post__author[href="/u/giacomo_forum"]});
$test->text_is( "$POST .post__avatar" => 'G' );
$test->element_exists(qq{$POST time[datetime="$WRITTEN"]});
$test->element_exists(qq{$POST .post__permalink[href="#post-post-1"]});

# Its actions open in sheets: popovers the browser opens, closes and returns
# focus from, with no script.
for my $action (qw(edit delete report)) {
    my $sheet = "post-post-1-$action";
    $test->element_exists(qq{$POST button[popovertarget="$sheet"]});
    $test->element_exists(qq{div#$sheet.sheet[popover][role="dialog"] form});
}
$test->element_exists('#post-post-1-edit form[action="/p/post-1"] textarea');
$test->element_exists('#post-post-1-report form[action="/p/post-1/report"]');

# Deleting is never one click away: the sheet says what will happen first.
$test->element_exists_not(qq{$POST > footer > form[action="/p/post-1/delete"]});
$test->element_exists('#post-post-1-delete form[action="/p/post-1/delete"]');
$test->text_like( '#post-post-1-delete .sheet__consequence' =>
      qr/can [ ] restore [ ] it/msx );
$test->text_like(
    '#thread-tools .sheet__consequence' => qr/can [ ] restore [ ] it/msx );

# A button that opens or closes a sheet names one that is on the page.
my @dangling = grep { !_is_sheet( $dom, $_ ) }
  $dom->find('[popovertarget]')->map( attr => 'popovertarget' )->each;
is_deeply( \@dangling, [], 'every sheet button names a sheet' );
cmp_ok( $dom->find('.sheet')->size, '>', 0, 'and there are sheets to name' );

# Each sheet has a name of its own and a way out.
for my $sheet ( $dom->find('.sheet')->each ) {
    my $id = $sheet->attr('id');
    is( $sheet->attr('aria-labelledby'),
        "$id-heading", "$id is labelled by its heading" );
    ok( $sheet->at(qq{h2[id="$id-heading"]}), "$id has that heading" );
    ok( $sheet->at(qq{button[popovertarget="$id"][popovertargetaction="hide"]}),
        "$id has a button that closes it" );
}

# A reader who is not signed in gets the conversation and nothing to manage.
my $anonymous = Test::Mojo->new('GPForum');
_install_forum_fakes($anonymous);
$anonymous->get_ok('/t/thread-1');
$anonymous->status_is($HTTP_OK);
$anonymous->element_exists($POST);
$anonymous->element_exists_not('.sheet');
$anonymous->element_exists_not('[popovertarget]');

done_testing();

# The ids of the page's fields that are not inside a sheet.
sub _fields_outside_sheets {
    my ($page) = @_;

    return [
        map  { $_->attr('id') // $_->attr('name') }
        grep { !$_->ancestors('.sheet')->size }
          $page->at('main')->find($FIELDS)->each
    ];
}

sub _is_sheet {
    my ( $page, $id ) = @_;

    return $page->at(qq{[id="$id"][popover]}) ? 1 : 0;
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
        gp_command_idempotency => sub {
            return GPForum::Test::CommandIdempotency->new;
        }
    );

    return;
}

sub _install_session_route {
    my ($test_object) = @_;

    my $routes = $test_object->app->routes;
    $routes->get('/__test/session/:user_id')->to(
        cb => sub {
            my ($controller) = @_;

            $controller->session( user_id => $controller->param('user_id') );
            return $controller->render( json => { ok => 1 } );
        }
    );

    return;
}

1;
