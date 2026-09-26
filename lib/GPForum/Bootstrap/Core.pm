# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Bootstrap::Core;

use strict;
use warnings;
use feature 'signatures';

use GPForum::Service::Clock;
use GPForum::Infrastructure::Id;
use GPForum::Service::Forum::Readability;
use GPForum::Service::Realtime::ChannelAuthorizer;
use GPForum::Service::Realtime::Hub;
use GPForum::Service::Realtime::ListenerSupervisor;
use GPForum::Service::Realtime::PgListener;
use GPForum::Service::Realtime::PgNotifier;
use GPForum::Service::Realtime::SubscriptionPolicy;

our $VERSION = '0.001';

sub register {
    my ( undef, %input ) = @_;

    my $application = $input{application};
    my $config      = $input{config};

    $application->secrets( $config->signing_secrets );
    $application->mode( $config->environment );
    _configure_static_assets($application);

    $application->helper(
        gp_clock => sub { return GPForum::Service::Clock->new; } );
    $application->helper(
        gp_id => sub { return GPForum::Infrastructure::Id->new; } );

    my $realtime_hub;
    $application->helper(
        gp_realtime_hub => sub {
            my ($controller) = @_;

            return $realtime_hub if $realtime_hub;

            my $readability = GPForum::Service::Forum::Readability->new(
                schema => $controller->gp_schema );
            $realtime_hub = GPForum::Service::Realtime::Hub->new(
                authorizer =>
                  GPForum::Service::Realtime::ChannelAuthorizer->new(
                    permission_engine =>
                      GPForum::Service::Realtime::SubscriptionPolicy->new(
                        permission_gate  => $controller->gp_permission_gate,
                        readability      => $readability,
                        schema           => $controller->gp_schema,
                        suspension_store => $controller->gp_suspension_store,
                      ),
                  ),
                readability => $readability,
            );
            return $realtime_hub;
        }
    );

    my $realtime_pg_notifier;
    $application->helper(
        gp_realtime_pg_notifier => sub {
            my ($controller) = @_;

            $realtime_pg_notifier ||=
              GPForum::Service::Realtime::PgNotifier->new(
                schema => $controller->gp_schema, );
            return $realtime_pg_notifier;
        }
    );

    my $realtime_pg_listener;
    $application->helper(
        gp_realtime_pg_listener => sub {
            my ($controller) = @_;

            $realtime_pg_listener ||=
              GPForum::Service::Realtime::PgListener->new(
                hub    => $controller->gp_realtime_hub,
                schema => $controller->gp_schema,
              );
            return $realtime_pg_listener;
        }
    );

    my $realtime_listener_supervisor;
    $application->helper(
        gp_realtime_listener_supervisor => sub {
            my ($controller) = @_;

            $realtime_listener_supervisor ||=
              GPForum::Service::Realtime::ListenerSupervisor->new(
                enabled => $config->realtime_listener_enabled,
                heartbeat_interval_seconds =>
                  $config->realtime_listener_heartbeat_interval_seconds,
                listener              => $controller->gp_realtime_pg_listener,
                logger                => $controller->app->log,
                poll_interval_seconds =>
                  $config->realtime_listener_poll_interval_seconds,
                reconnect_backoff_seconds =>
                  $config->realtime_listener_reconnect_backoff_seconds,
              );
            return $realtime_listener_supervisor;
        }
    );
    _configure_realtime_listener_lifecycle( $application, $config );

    return;
}

sub _configure_static_assets ($application) {
    my $paths = $application->static->paths;
    push @{$paths},
      $application->home->rel_file('assets/css')->to_string,
      $application->home->rel_file('assets/img')->to_string;

    return;
}

sub _configure_realtime_listener_lifecycle {
    my ( $application, $config ) = @_;

    return if !$config->realtime_listener_enabled;

    $application->hook(
        before_dispatch => sub {
            my ($controller) = @_;

            $controller->gp_realtime_listener_supervisor->start;
        }
    );

    return;
}

1;
