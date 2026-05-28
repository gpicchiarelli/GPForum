package main;

use strict;
use warnings;

use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Bootstrap::Workers;
use GPForum::Command::OutboxDispatch;
use GPForum::Config;
use GPForum::Service::Outbox::Dispatcher;
use GPForum::Service::Outbox::DomainEventTransport;
use GPForum::Worker::MinionRegistrar;
use Mojolicious;

our $VERSION = '0.001';

{

    package GPForum::Test::OutboxCommandDispatcher;

    sub new {
        my ($class) = @_;

        return bless { calls => [] }, $class;
    }

    sub calls {
        my ($self) = @_;

        return $self->{calls};
    }

    sub dispatch_pending {
        my ( $self, $limit ) = @_;

        push @{ $self->{calls} }, $limit;

        return {
            selected      => $limit,
            dispatched    => $limit,
            failed        => 0,
            dead_lettered => 0,
        };
    }
}

my $application = Mojolicious->new;
$application->secrets( ['workers-bootstrap-test'] );
_install_worker_helper_dependencies($application);

GPForum::Bootstrap::Workers->register(
    application => $application,
    config      => GPForum::Config->new,
);

my $controller = $application->build_controller;
isa_ok(
    $controller->gp_outbox_transport,
    'GPForum::Service::Outbox::DomainEventTransport',
    'workers bootstrap registers outbox transport helper'
);
isa_ok(
    $controller->gp_outbox_dispatcher,
    'GPForum::Service::Outbox::Dispatcher',
    'workers bootstrap registers outbox dispatcher helper'
);
isa_ok(
    $controller->gp_worker_registrar,
    'GPForum::Worker::MinionRegistrar',
    'workers bootstrap registers worker registrar helper'
);

throws_ok(
    sub {
        GPForum::Config->new( minion_enabled => 1 )->validate;
    },
    qr/\A minion_pg_url [ ] is [ ] required/msx,
    'Minion enablement requires explicit PostgreSQL URL'
);

my $dispatcher = GPForum::Test::OutboxCommandDispatcher->new;
my @sleeps;
my $output = q{};
open my $output_handle, '>', \$output or die 'failed to open scalar output';
my $command = GPForum::Command::OutboxDispatch->new(
    dispatcher => $dispatcher,
    output     => $output_handle,
    sleeper    => sub {
        my ($seconds) = @_;

        push @sleeps, $seconds;

        return;
    },
);

my $exit = $command->run( '--loop', '--limit', '3', '--sleep', '2',
    '--max-iterations', '2', );
is( $exit, 0, 'outbox dispatch command exits successfully' );
is_deeply(
    $dispatcher->calls,
    [ 3, 3 ],
    'outbox dispatch loop calls dispatcher for each iteration'
);
is_deeply( \@sleeps, [2], 'outbox dispatch loop sleeps between iterations' );
like(
    $output,
qr/outbox_dispatch [ ] selected=3 [ ] dispatched=3 [ ] failed=0 [ ] dead_lettered=0/msx,
    'outbox dispatch command prints operational summary'
);

throws_ok(
    sub {
        GPForum::Command::OutboxDispatch->new( dispatcher => $dispatcher )
          ->run('--bad-option');
    },
    qr/\A unknown [ ] option [ ] --bad-option/msx,
    'outbox dispatch command rejects unknown options'
);

done_testing();

sub _install_worker_helper_dependencies {
    my ($application) = @_;

    $application->helper( gp_schema                  => sub { return {}; } );
    $application->helper( gp_realtime_pg_notifier    => sub { return {}; } );
    $application->helper( gp_notification_dispatcher => sub { return {}; } );
    $application->helper( gp_local_cache             => sub { return {}; } );
    $application->helper( gp_attachment_storage      => sub { return {}; } );
    $application->helper( gp_attachment_store        => sub { return {}; } );
    $application->helper( gp_media_processor         => sub { return {}; } );

    return;
}

1;
