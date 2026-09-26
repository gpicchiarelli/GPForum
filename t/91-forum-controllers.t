# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Bootstrap::Routes;
use GPForum::Controller::Forum;
use GPForum::Controller::Forum::Base;
use GPForum::Controller::Forum::Community;
use GPForum::Controller::Forum::Search;
use GPForum::Controller::Forum::Write;
use Mojolicious;
use Test::More;

our $VERSION = '0.001';

ok(
    GPForum::Controller::Forum->can('categories'),
    'read controller keeps category listing'
);
ok(
    !$GPForum::Controller::Forum::{create_thread},
    'read controller no longer owns writes'
);
ok( $GPForum::Controller::Forum::Write::{create_thread},
    'write controller owns thread creation' );
ok(
    $GPForum::Controller::Forum::Community::{feed},
    'community controller owns the member feed'
);
ok(
    $GPForum::Controller::Forum::Search::{search},
    'search controller owns HTML search'
);
isa_ok( 'GPForum::Controller::Forum::Write',
    'GPForum::Controller::Forum::Base' );
isa_ok(
    'GPForum::Controller::Forum::Community',
    'GPForum::Controller::Forum::Base'
);
isa_ok( 'GPForum::Controller::Forum::Search',
    'GPForum::Controller::Forum::Base' );

my $app = Mojolicious->new;
GPForum::Bootstrap::Routes->register( application => $app );
_assert_route( $app, 'categories',    'Forum',            'categories' );
_assert_route( $app, 'thread_create', 'Forum::Write',     'create_thread' );
_assert_route( $app, 'feed',          'Forum::Community', 'feed' );
_assert_route( $app, 'thread_report', 'Forum::Community', 'report_thread' );
_assert_route( $app, 'forum_search',  'Forum::Search',    'search' );
_assert_route( $app, 'search_autocomplete',
    'Forum::Search', 'search_autocomplete' );

done_testing();

sub _assert_route {
    my ( $application, $name, $controller, $action ) = @_;

    my $to = $application->routes->find($name)->to;
    is( $to->{controller}, $controller, "$name uses $controller" );
    is( $to->{action},     $action,     "$name uses $action" );

    return;
}

1;
