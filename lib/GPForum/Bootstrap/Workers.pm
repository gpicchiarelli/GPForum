# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Bootstrap::Workers;

use strict;
use warnings;
use feature 'signatures';

use Carp          qw(croak);
use English       qw(-no_match_vars);
use Sys::Hostname qw(hostname);

use GPForum::Service::Community::FeedProjector;
use GPForum::Service::Community::ReputationLedger;
use GPForum::Service::Outbox::Dispatcher;
use GPForum::Service::Outbox::DomainEventTransport;
use GPForum::Service::Search::Indexer;
use GPForum::Service::Search::RebuildRun;
use GPForum::Worker::EventIdempotencyStore;
use GPForum::Worker::Handler::AttachmentScanning;
use GPForum::Worker::Handler::CacheInvalidation;
use GPForum::Worker::Handler::FeedProjection;
use GPForum::Worker::Handler::IdentityMail;
use GPForum::Worker::Handler::MediaProcessing;
use GPForum::Worker::Handler::NotificationDispatch;
use GPForum::Worker::Handler::ReputationUpdate;
use GPForum::Worker::Handler::SearchIndexing;
use GPForum::Worker::Handler::ThreadActivity;
use GPForum::Worker::IdempotentJobRunner;
use GPForum::Worker::MinionGuard;
use GPForum::Worker::MinionRegistrar;

our $VERSION = '0.001';

sub register ( $, %input ) {
    my $application = $input{application};
    my $config      = $input{config};

    _register_worker_helpers($application);
    _configure_minion( $application, $config );

    return;
}

sub _register_worker_helpers {
    my ($application) = @_;

    $application->helper(
        gp_outbox_transport => sub {
            my ($controller) = @_;

            return GPForum::Service::Outbox::DomainEventTransport->new(
                handlers          => _event_handlers($controller),
                job_runner        => _job_runner($controller),
                realtime_notifier => $controller->gp_realtime_pg_notifier,
            );
        }
    );

    $application->helper(
        gp_outbox_dispatcher => sub {
            my ($controller) = @_;

            return GPForum::Service::Outbox::Dispatcher->new(
                schema    => $controller->gp_schema,
                transport => $controller->gp_outbox_transport,
                worker_id => _worker_id(),
            );
        }
    );

    $application->helper(
        gp_worker_registrar => sub {
            return GPForum::Worker::MinionRegistrar->new(
                dispatcher_factory => sub {
                    my ($job) = @_;

                    return $job->app->build_controller->gp_outbox_dispatcher;
                },
            );
        }
    );

    return;
}

sub _job_runner ($controller) {
    return GPForum::Worker::IdempotentJobRunner->new(
        store => GPForum::Worker::EventIdempotencyStore->new(
            schema => $controller->gp_schema,
        ),
    );
}

sub _event_handlers ($controller) {
    return [
        _search_handler($controller),
        GPForum::Worker::Handler::NotificationDispatch->new(
            dispatcher => $controller->gp_notification_dispatcher,
        ),
        GPForum::Worker::Handler::CacheInvalidation->new(
            cache => $controller->gp_local_cache,
        ),
        GPForum::Worker::Handler::ThreadActivity->new(
            schema => $controller->gp_schema,
        ),
        GPForum::Worker::Handler::AttachmentScanning->new(
            antivirus => $controller->gp_antivirus,
            storage   => $controller->gp_attachment_storage,
            store     => $controller->gp_attachment_store,
        ),
        GPForum::Worker::Handler::MediaProcessing->new(
            processor => $controller->gp_media_processor,
        ),
        GPForum::Worker::Handler::FeedProjection->new(
            projector => GPForum::Service::Community::FeedProjector->new(
                schema => $controller->gp_schema,
            ),
            schema             => $controller->gp_schema,
            subscription_store => $controller->gp_subscription_store,
        ),
        GPForum::Worker::Handler::IdentityMail->new(
            mailer => $controller->gp_identity_mailer,
        ),
        GPForum::Worker::Handler::ReputationUpdate->new(
            ledger => GPForum::Service::Community::ReputationLedger->new(
                schema => $controller->gp_schema,
            ),
            schema => $controller->gp_schema,
        ),
    ];
}

sub _search_handler ($controller) {
    my $indexer =
      GPForum::Service::Search::Indexer->new(
        schema => $controller->gp_schema );

    return GPForum::Worker::Handler::SearchIndexing->new(
        indexer     => $indexer,
        rebuild_run => GPForum::Service::Search::RebuildRun->new(
            indexer => $indexer,
            schema  => $controller->gp_schema,
        ),
    );
}

sub _configure_minion ( $application, $config ) {
    if ( !GPForum::Worker::MinionGuard->requested($config) ) {
        return;
    }

    _require_minion_backend($config);
    GPForum::Worker::MinionGuard->wrap(
        sub {
            _load_minion_plugin( $application, $config );
            return;
        }
    );
    GPForum::Worker::MinionGuard->wrap(
        sub {
            GPForum::Worker::MinionGuard->assert_reachable(
                $application->minion );
            return;
        }
    );
    _register_minion_tasks($application);

    return;
}

sub _load_minion_plugin ( $application, $config ) {
    $application->plugin( Minion => { Pg => $config->minion_pg_url } );

    return 1;
}

sub _register_minion_tasks {
    my ($application) = @_;

    my $tasks = GPForum::Worker::MinionRegistrar->new(
        dispatcher_factory => sub {
            my ($job) = @_;

            return $job->app->build_controller->gp_outbox_dispatcher;
        },
    )->register( $application->minion );
    $application->config( gpforum_minion_tasks => $tasks );

    return;
}

sub _require_minion_backend ($config) {
    croak 'GPFORUM_MINION_PG_URL is required when GPFORUM_MINION_ENABLED=1'
      if !length $config->minion_pg_url;

    my $ok = eval {
        require Mojolicious::Plugin::Minion;
        require Minion::Backend::Pg;
        require Mojo::Pg;
        return 1;
    };
    return if $ok;

    croak
'Minion PostgreSQL backend requires Mojo::Pg; install optional PostgreSQL dependencies: '
      . $EVAL_ERROR;
}

sub _worker_id {
    return join q{:}, 'gpforum', hostname(), $PROCESS_ID;
}

1;
