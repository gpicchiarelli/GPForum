package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Bootstrap::Routes;
use GPForum::Controller::Notifications;
use GPForum::Controller::Notifications::Base;
use GPForum::Controller::Notifications::Mentions;
use GPForum::Controller::Notifications::Read;
use Mojolicious;
use Test::More;

our $VERSION = '0.001';

ok(
    GPForum::Controller::Notifications->can('inbox'),
    'parent controller keeps the notification inbox'
);
ok(
    !$GPForum::Controller::Notifications::{mark_read},
    'parent controller no longer owns mark-read writes'
);
ok(
    !$GPForum::Controller::Notifications::{mentions},
    'parent controller no longer owns mention reads'
);
ok( $GPForum::Controller::Notifications::Read::{mark_read},
    'read controller owns mark-read writes' );
ok( $GPForum::Controller::Notifications::Read::{mark_all_read},
    'read controller owns mark-all-read writes' );
ok( $GPForum::Controller::Notifications::Mentions::{mentions},
    'mentions controller owns mention reads' );
isa_ok(
    'GPForum::Controller::Notifications',
    'GPForum::Controller::Notifications::Base'
);
isa_ok(
    'GPForum::Controller::Notifications::Read',
    'GPForum::Controller::Notifications::Base'
);
isa_ok(
    'GPForum::Controller::Notifications::Mentions',
    'GPForum::Controller::Notifications::Base'
);

my $app = Mojolicious->new;
GPForum::Bootstrap::Routes->register( application => $app );
_assert_route( $app, 'notifications',     'Notifications',       'inbox' );
_assert_route( $app, 'notification_read', 'Notifications::Read', 'mark_read' );
_assert_route( $app, 'notifications_read_all', 'Notifications::Read',
    'mark_all_read' );
_assert_route( $app, 'mentions', 'Notifications::Mentions', 'mentions' );

done_testing();

sub _assert_route {
    my ( $application, $name, $controller, $action ) = @_;

    my $to = $application->routes->find($name)->to;
    is( $to->{controller}, $controller, "$name uses $controller" );
    is( $to->{action},     $action,     "$name uses $action" );

    return;
}

1;
