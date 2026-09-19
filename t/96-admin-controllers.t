package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Bootstrap::Routes;
use GPForum::Controller::Admin;
use GPForum::Controller::Admin::Base;
use GPForum::Controller::Admin::Bindings;
use GPForum::Controller::Admin::Catalog;
use GPForum::Controller::Admin::Categories;
use Mojo::Transaction::HTTP;
use Mojolicious;
use Test::More;

our $VERSION = '0.001';

my @KEEP_ALIVE;

ok(
    GPForum::Controller::Admin->can('dashboard'),
    'review controller keeps the dashboard'
);
ok(
    !$GPForum::Controller::Admin::{create_role},
    'review controller no longer owns catalog writes'
);
ok( $GPForum::Controller::Admin::Catalog::{create_role},
    'catalog controller owns role creation' );
ok( $GPForum::Controller::Admin::Bindings::{bind_role},
    'binding controller owns role binding' );
ok( $GPForum::Controller::Admin::Categories::{create_category},
    'category controller owns category creation' );
ok(
    GPForum::Controller::Admin->can('categories'),
    'review controller keeps the category catalog'
);
ok(
    !$GPForum::Controller::Admin::{create_category},
    'review controller no longer owns category writes'
);
isa_ok( 'GPForum::Controller::Admin', 'GPForum::Controller::Admin::Base' );
isa_ok( 'GPForum::Controller::Admin::Catalog',
    'GPForum::Controller::Admin::Base' );
isa_ok(
    'GPForum::Controller::Admin::Bindings',
    'GPForum::Controller::Admin::Base'
);
isa_ok(
    'GPForum::Controller::Admin::Categories',
    'GPForum::Controller::Admin::Base'
);

my $app = Mojolicious->new;
GPForum::Bootstrap::Routes->register( application => $app );
_assert_route( $app, 'admin_dashboard',  'Admin', 'dashboard' );
_assert_route( $app, 'admin_roles',      'Admin', 'roles' );
_assert_route( $app, 'admin_categories', 'Admin', 'categories' );
_assert_route( $app, 'admin_category_create',
    'Admin::Categories', 'create_category' );
_assert_route( $app, 'admin_category_update',
    'Admin::Categories', 'update_category' );
_assert_route( $app, 'admin_user_roles',  'Admin',          'user_roles' );
_assert_route( $app, 'admin_role_create', 'Admin::Catalog', 'create_role' );
_assert_route( $app, 'admin_permission_create',
    'Admin::Catalog', 'create_permission' );
_assert_route( $app, 'admin_role_permission_attach',
    'Admin::Catalog', 'attach_permission' );
_assert_route( $app, 'admin_role_bind', 'Admin::Bindings', 'bind_role' );
_assert_route( $app, 'admin_role_binding_revoke',
    'Admin::Bindings', 'revoke_binding' );

is_deeply(
    _optional_filter_hash( _controller_with_query( {} ) ),
    {
        after => undef,
        limit => 'kept',
    },
    'optional_param keeps following hash keys when a filter is empty'
);
is_deeply(
    _optional_filter_hash( _controller_with_query( { after => 'cursor-1' } ) ),
    {
        after => 'cursor-1',
        limit => 'kept',
    },
    'optional_param keeps a present filter value'
);

done_testing();

sub _assert_route {
    my ( $application, $name, $controller, $action ) = @_;

    my $to = $application->routes->find($name)->to;
    is( $to->{controller}, $controller, "$name uses $controller" );
    is( $to->{action},     $action,     "$name uses $action" );

    return;
}

sub _controller_with_query {
    my ($query) = @_;

    my $application = Mojolicious->new;
    my $tx          = Mojo::Transaction::HTTP->new;
    my $controller  = GPForum::Controller::Admin::Base->new;
    $tx->req->url->query($query);
    $controller->app($application);
    $controller->tx($tx);
    push @KEEP_ALIVE, $application, $tx, $controller;

    return $controller;
}

sub _optional_filter_hash {
    my ($controller) = @_;

    return {
        after => $controller->optional_param('after'),
        limit => 'kept',
    };
}

1;
