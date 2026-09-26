# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Bootstrap::Workers;
use GPForum::Command::OutboxDispatch;
use GPForum::Config;
use GPForum::Service::Outbox::Dispatcher;
use GPForum::Service::Outbox::DomainEventTransport;
use GPForum::Test::OutboxCommandDispatcher;
use GPForum::Test::UnreachableMinion;
use GPForum::Worker::MinionGuard;
use GPForum::Worker::MinionRegistrar;
use Mojolicious;

our $VERSION = '0.001';

# Messages each pass of the draining loop claims, with --limit 3: full,
# short, full, none, short, and then full again.
const my @CLAIMED      => ( 3, 1, 3, 0, 2 );
const my $DRAIN_PASSES => 6;

my $minion_unavailable =
  qr{Minion [ ] PostgreSQL [ ] backend [ ] is [ ] unavailable:}msx;
my $minion_connection = qr{connection [ ] refused}msx;
my $minion_ping       = qr{Minion [ ] PostgreSQL [ ] ping [ ] failed}msx;

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
like(
    $output,
qr/outbox_dispatch [ ] selected=3 [ ] dispatched=3 [ ] failed=0 [ ] dead_lettered=0/msx,
    'outbox dispatch command prints operational summary'
);

# It slept after every batch, so however large the backlog it delivered at
# most --limit messages per --sleep seconds, with realtime, notifications and
# cache purges waiting behind it. A full batch now goes straight on to the
# next; only a short one, the backlog drained, waits.
is_deeply( \@sleeps, [], 'a full batch goes straight on to the next' );

@sleeps = ();
my $draining =
  GPForum::Test::OutboxCommandDispatcher->new( selected => [@CLAIMED] );
my $draining_command = GPForum::Command::OutboxDispatch->new(
    dispatcher => $draining,
    output     => $output_handle,
    sleeper    => sub {
        my ($seconds) = @_;

        push @sleeps, $seconds;

        return;
    },
);
$draining_command->run( '--loop', '--limit', '3', '--sleep', '2',
    '--max-iterations', $DRAIN_PASSES );
is_deeply(
    \@sleeps,
    [ 2, 2, 2 ],
    'a short or empty batch sleeps before the next'
);
is( scalar @{ $draining->calls },
    $DRAIN_PASSES, 'and the loop still runs every pass' );

throws_ok(
    sub {
        GPForum::Command::OutboxDispatch->new( dispatcher => $dispatcher )
          ->run('--bad-option');
    },
    qr/\A unknown [ ] option [ ] --bad-option/msx,
    'outbox dispatch command rejects unknown options'
);

ok(
    GPForum::Worker::MinionGuard->requested(
        _enabled_minion_config(), 'hypnotoad'
    ),
    'web process requests Minion when it is enabled'
);
ok(
    !GPForum::Worker::MinionGuard->requested(
        _enabled_minion_config(), '/opt/gpforum/bin/gpforum-outbox-dispatch'
    ),
    'direct outbox process skips Minion when it is enabled'
);
ok(
    !GPForum::Worker::MinionGuard->requested(
        GPForum::Config->new, 'hypnotoad'
    ),
    'web process skips Minion when it is disabled'
);

throws_ok(
    sub {
        GPForum::Worker::MinionGuard->wrap(
            sub { croak "connection refused\n"; } );
    },
    qr{\A $minion_unavailable [ ] $minion_connection}msx,
    'Minion enablement fails closed when the backend is absent'
);

my $unreachable = GPForum::Test::UnreachableMinion->new;
ok(
    !GPForum::Worker::MinionGuard->reachable($unreachable),
    'Minion guard treats a failed ping as unreachable'
);
throws_ok(
    sub {
        GPForum::Worker::MinionGuard->wrap(
            sub {
                GPForum::Worker::MinionGuard->assert_reachable($unreachable);
                return;
            }
        );
    },
    qr{\A $minion_unavailable [ ] $minion_ping}msx,
    'Minion enablement fails closed when the backend ping fails'
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
    $application->helper( gp_subscription_store      => sub { return {}; } );
    $application->helper( gp_identity_mailer         => sub { return {}; } );

    # Scanning off. A scalar undef, not an empty list: the helper's value is
    # an argument in a constructor's key/value list.
    $application->helper(
        gp_antivirus => sub {
            my $none;
            return $none;
        }
    );

    return;
}

sub _enabled_minion_config {
    return GPForum::Config->new(
        minion_enabled => 1,
        minion_pg_url  => 'postgresql://gpforum@/gpforum_minion',
    );
}

1;
