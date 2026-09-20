package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Bootstrap::Routes;
use GPForum::Controller::Moderation;
use GPForum::Controller::Moderation::Actions;
use GPForum::Controller::Moderation::Base;
use GPForum::Controller::Moderation::Queue;
use GPForum::Controller::Moderation::Suspensions;
use Mojo::Transaction::HTTP;
use Mojolicious;
use Test::More;

our $VERSION = '0.001';

my @KEEP_ALIVE;

ok(
    GPForum::Controller::Moderation->can('reports'),
    'review controller keeps the report queue'
);
ok(
    !$GPForum::Controller::Moderation::{hide_post},
    'review controller no longer owns content writes'
);
ok( $GPForum::Controller::Moderation::Queue::{assign_report},
    'queue controller owns report assignment' );
ok( $GPForum::Controller::Moderation::Actions::{hide_post},
    'action controller owns post hiding' );
ok( $GPForum::Controller::Moderation::Actions::{hide_thread},
    'action controller owns thread hiding' );
ok( $GPForum::Controller::Moderation::Suspensions::{suspend_user},
    'suspension controller owns user suspension' );
isa_ok(
    'GPForum::Controller::Moderation',
    'GPForum::Controller::Moderation::Base'
);
isa_ok(
    'GPForum::Controller::Moderation::Queue',
    'GPForum::Controller::Moderation::Base'
);
isa_ok(
    'GPForum::Controller::Moderation::Actions',
    'GPForum::Controller::Moderation::Base'
);
isa_ok(
    'GPForum::Controller::Moderation::Suspensions',
    'GPForum::Controller::Moderation::Base'
);

my $app = Mojolicious->new;
GPForum::Bootstrap::Routes->register( application => $app );
_assert_route( $app, 'moderation_reports',     'Moderation', 'reports' );
_assert_route( $app, 'moderation_actions',     'Moderation', 'actions' );
_assert_route( $app, 'moderation_suspensions', 'Moderation', 'suspensions' );
_assert_route( $app, 'moderation_report_assign',
    'Moderation::Queue', 'assign_report' );
_assert_route( $app, 'moderation_report_resolve',
    'Moderation::Queue', 'resolve_report' );
_assert_route( $app, 'moderation_post_hide',
    'Moderation::Actions', 'hide_post' );
_assert_route( $app, 'moderation_thread_lock',
    'Moderation::Actions', 'lock_thread' );
_assert_route( $app, 'moderation_thread_hide',
    'Moderation::Actions', 'hide_thread' );
_assert_route( $app, 'moderation_thread_restore',
    'Moderation::Actions', 'restore_thread' );
_assert_route( $app, 'moderation_action_reverse',
    'Moderation::Actions', 'reverse_action' );
_assert_route( $app, 'moderation_user_suspend',
    'Moderation::Suspensions', 'suspend_user' );
_assert_route( $app, 'moderation_suspension_revoke',
    'Moderation::Suspensions', 'revoke_suspension' );

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

is(
    _controller_with_query( { command_id => 'hide-command-1' } )
      ->command_id_param,
    'hide-command-1',
    'command_id_param reads the Forum-style command_id field'
);
is(
    _controller_with_query( { idempotency_key => 'hide-command-2' } )
      ->command_id_param,
    'hide-command-2',
    'command_id_param falls back to idempotency_key'
);
is( _controller_with_query( {} )->command_id_param,
    q{}, 'command_id_param is empty when neither key is supplied' );

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
    my $controller  = GPForum::Controller::Moderation::Base->new;
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
