package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Bootstrap::Routes;
use GPForum::Controller::Privacy;
use GPForum::Controller::Privacy::Base;
use GPForum::Controller::Privacy::Requests;
use GPForum::Controller::Privacy::Review;
use Mojo::Transaction::HTTP;
use Mojolicious;
use Test::More;

our $VERSION = '0.001';

my @KEEP_ALIVE;

ok( GPForum::Controller::Privacy->can('download_export'),
    'member controller owns export download' );
ok(
    !$GPForum::Controller::Privacy::{request_export},
    'member controller no longer owns export writes'
);
ok(
    !$GPForum::Controller::Privacy::{approve_deletion},
    'member controller no longer owns staff writes'
);
ok(
    $GPForum::Controller::Privacy::Requests::{request_export},
    'request controller owns member export writes'
);
ok(
    $GPForum::Controller::Privacy::Requests::{request_deletion},
    'request controller owns member deletion writes'
);
ok(
    $GPForum::Controller::Privacy::Review::{review},
    'review controller owns the staff queue'
);
ok( $GPForum::Controller::Privacy::Review::{approve_deletion},
    'review controller owns deletion approval' );
ok( $GPForum::Controller::Privacy::Review::{hold_deletion},
    'review controller owns legal holds' );
ok( $GPForum::Controller::Privacy::Review::{run_erasure_job},
    'review controller owns erasure jobs' );
isa_ok( 'GPForum::Controller::Privacy', 'GPForum::Controller::Privacy::Base' );
isa_ok(
    'GPForum::Controller::Privacy::Requests',
    'GPForum::Controller::Privacy::Base'
);
isa_ok(
    'GPForum::Controller::Privacy::Review',
    'GPForum::Controller::Privacy::Base'
);

my $app = Mojolicious->new;
GPForum::Bootstrap::Routes->register( application => $app );
_assert_route( $app, 'privacy_dashboard',       'Privacy', 'dashboard' );
_assert_route( $app, 'privacy_export_download', 'Privacy', 'download_export' );
_assert_route( $app, 'privacy_export_request',
    'Privacy::Requests', 'request_export' );
_assert_route( $app, 'privacy_deletion_request',
    'Privacy::Requests', 'request_deletion' );
_assert_route( $app, 'privacy_review', 'Privacy::Review', 'review' );
_assert_route( $app, 'privacy_deletion_approve',
    'Privacy::Review', 'approve_deletion' );
_assert_route( $app, 'privacy_deletion_hold',
    'Privacy::Review', 'hold_deletion' );
_assert_route( $app, 'privacy_erasure_run',
    'Privacy::Review', 'run_erasure_job' );

is(
    _controller_with_query( { command_id => 'export-command-1' } )
      ->command_id_param,
    'export-command-1',
    'command_id_param reads the Forum-style command_id field'
);
is(
    _controller_with_query( { idempotency_key => 'export-command-2' } )
      ->command_id_param,
    'export-command-2',
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
    my $controller  = GPForum::Controller::Privacy::Base->new;
    $tx->req->url->query($query);
    $controller->app($application);
    $controller->tx($tx);
    push @KEEP_ALIVE, $application, $tx, $controller;

    return $controller;
}

1;
