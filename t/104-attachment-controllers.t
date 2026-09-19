package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Bootstrap::Routes;
use GPForum::Controller::Attachments;
use GPForum::Controller::Attachments::Base;
use GPForum::Controller::Attachments::Upload;
use Mojolicious;
use Test::More;

our $VERSION = '0.001';

ok(
    GPForum::Controller::Attachments->can('download'),
    'parent controller keeps attachment downloads'
);
ok(
    !$GPForum::Controller::Attachments::{upload_post},
    'parent controller no longer owns attachment uploads'
);
ok(
    $GPForum::Controller::Attachments::Upload::{upload_post},
    'upload controller owns post attachment writes'
);
isa_ok(
    'GPForum::Controller::Attachments',
    'GPForum::Controller::Attachments::Base'
);
isa_ok(
    'GPForum::Controller::Attachments::Upload',
    'GPForum::Controller::Attachments::Base'
);

my $app = Mojolicious->new;
GPForum::Bootstrap::Routes->register( application => $app );
_assert_route( $app, 'attachment_download', 'Attachments', 'download' );
_assert_route( $app, 'post_attachment_upload',
    'Attachments::Upload', 'upload_post' );

done_testing();

sub _assert_route {
    my ( $application, $name, $controller, $action ) = @_;

    my $to = $application->routes->find($name)->to;
    is( $to->{controller}, $controller, "$name uses $controller" );
    is( $to->{action},     $action,     "$name uses $action" );

    return;
}

1;
