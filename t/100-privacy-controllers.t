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
use Mojolicious;
use Test::More;

our $VERSION = '0.001';

ok(
    GPForum::Controller::Privacy->can('dashboard'),
    'member controller keeps the dashboard'
);
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
_assert_route( $app, 'privacy_dashboard', 'Privacy', 'dashboard' );
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

done_testing();

sub _assert_route {
    my ( $application, $name, $controller, $action ) = @_;

    my $to = $application->routes->find($name)->to;
    is( $to->{controller}, $controller, "$name uses $controller" );
    is( $to->{action},     $action,     "$name uses $action" );

    return;
}

1;
