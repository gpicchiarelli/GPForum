# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Bootstrap::Forum;

use strict;
use warnings;
use feature 'signatures';

use GPForum::Infrastructure::Antivirus;
use GPForum::Service::Attachment::Delivery;
use GPForum::Service::Attachment::FilesystemStorage;
use GPForum::Service::Attachment::IntentBuilder;
use GPForum::Service::Attachment::MediaProcessor;
use GPForum::Service::Attachment::Store;
use GPForum::Service::Attachment::UploadPipeline;
use GPForum::Service::Attachment::Workflow;
use GPForum::Service::Community::BookmarkStore;
use GPForum::Service::Community::FeedReader;
use GPForum::Service::Community::MentionReader;
use GPForum::Service::Community::MentionStore;
use GPForum::Service::Community::Workflow;
use GPForum::Service::Forum::CategoryReader;
use GPForum::Service::Forum::HomePageReader;
use GPForum::Service::Forum::PostComposer;
use GPForum::Service::Forum::PostPosition;
use GPForum::Service::Forum::PostReader;
use GPForum::Service::Forum::PostStore;
use GPForum::Service::Forum::PostingWorkflow;
use GPForum::Service::Forum::ReadState;
use GPForum::Service::Forum::ReadWorkflow;
use GPForum::Service::Forum::Readability;
use GPForum::Service::Forum::ThreadComposer;
use GPForum::Service::Forum::ThreadDetailReader;
use GPForum::Service::Forum::ThreadReader;
use GPForum::Service::Forum::ThreadStore;
use GPForum::Service::Forum::Viewer;
use GPForum::Service::Forum::ViewerResolver;
use GPForum::Service::Notification::Dispatcher;
use GPForum::Service::Notification::RecipientPolicy;
use GPForum::Service::Notification::PreferenceStore;
use GPForum::Service::Notification::Renderer;
use GPForum::Service::Notification::SubscriptionStore;
use GPForum::Service::Notification::Workflow;
use GPForum::Service::Search::PermissionEngine;
use GPForum::Service::Search::Searcher;
use GPForum::Web::PublicHttpCache;

our $VERSION = '0.001';

sub register ( $, %input ) {
    my $application = $input{application};
    my $config      = $input{config};

    _register_forum_helpers( $application, $config );
    _register_attachment_helpers($application);
    _register_community_helpers($application);
    _register_notification_helpers($application);
    _register_search_helpers($application);

    return;
}

sub _register_forum_helpers {
    my ( $application, $config ) = @_;

    $application->helper(
        gp_public_http_cache => sub {
            my ($controller) = @_;

            return GPForum::Web::PublicHttpCache->new(
                cache       => $controller->gp_local_cache,
                ttl_seconds => $config->category_cache_ttl_seconds,
            );
        }
    );

    # The request's reader for visibility (ADR 0102), resolved once and kept
    # on the stash: an anonymous request pays no query, a signed-in one one.
    $application->helper(
        gp_forum_viewer => sub {
            my ($controller) = @_;

            my $cached = $controller->stash('gp.forum_viewer');
            return $cached if $cached;

            my $user_id = $controller->session('user_id');
            my $viewer =
              defined $user_id && length $user_id
              ? GPForum::Service::Forum::ViewerResolver->new(
                logger => $controller->app->log,
                schema => $controller->gp_schema,
              )->resolve($user_id)
              : GPForum::Service::Forum::Viewer->anonymous;
            $controller->stash( 'gp.forum_viewer' => $viewer );

            return $viewer;
        }
    );
    $application->helper(
        gp_category_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::CategoryReader->new(
                cache             => $controller->gp_local_cache,
                cache_ttl_seconds => $config->category_cache_ttl_seconds,
                schema            => $controller->gp_schema,
            );
        }
    );
    $application->helper(
        gp_thread_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::ThreadReader->new(
                schema => $controller->gp_schema );
        }
    );
    $application->helper(
        gp_home_page_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::HomePageReader->new(
                category_reader => $controller->gp_category_reader,
                thread_reader   => $controller->gp_thread_reader,
            );
        }
    );
    $application->helper(
        gp_post_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::PostReader->new(
                schema => $controller->gp_schema );
        }
    );
    $application->helper(
        gp_thread_detail_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::ThreadDetailReader->new(
                schema      => $controller->gp_schema,
                post_reader => $controller->gp_post_reader,
            );
        }
    );
    $application->helper(
        gp_thread_composer => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::ThreadComposer->new(
                id_service => $controller->gp_id );
        }
    );
    $application->helper(
        gp_thread_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::ThreadStore->new(
                clock      => $controller->gp_clock,
                schema     => $controller->gp_schema,
                id_service => $controller->gp_id,
            );
        }
    );
    $application->helper(
        gp_post_composer => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::PostComposer->new(
                id_service => $controller->gp_id );
        }
    );
    $application->helper(
        gp_post_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::PostStore->new(
                clock      => $controller->gp_clock,
                schema     => $controller->gp_schema,
                id_service => $controller->gp_id,
            );
        }
    );
    $application->helper(
        gp_post_position => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::PostPosition->new(
                schema => $controller->gp_schema );
        }
    );
    $application->helper(
        gp_thread_read_state => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::ReadState->new(
                schema => $controller->gp_schema, );
        }
    );
    $application->helper(
        gp_thread_read_workflow => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::ReadWorkflow->new(
                command_idempotency => $controller->gp_command_idempotency,
                logger              => $controller->app->log,
                read_state          => $controller->gp_thread_read_state,
            );
        }
    );
    $application->helper(
        gp_posting_workflow => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::PostingWorkflow->new(
                category_reader      => $controller->gp_category_reader,
                command_idempotency  => $controller->gp_command_idempotency,
                logger               => $controller->app->log,
                mention_store        => $controller->gp_mention_store,
                post_composer        => $controller->gp_post_composer,
                post_reader          => $controller->gp_post_reader,
                post_store           => $controller->gp_post_store,
                thread_composer      => $controller->gp_thread_composer,
                thread_detail_reader => $controller->gp_thread_detail_reader,
                thread_store         => $controller->gp_thread_store,
            );
        }
    );

    return;
}

sub _register_attachment_helpers {
    my ($application) = @_;

    my $attachment_storage;

    # The system antivirus the configuration names (ADR 0108), or undef when
    # the operator turned scanning off. Built once: a scanner holds only its
    # socket path or command, and connects per scan.
    my ( $antivirus, $antivirus_built );
    $application->helper(
        gp_antivirus => sub {
            my ($controller) = @_;

            if ( !$antivirus_built ) {
                $antivirus = GPForum::Infrastructure::Antivirus->from_config(
                    $controller->gp_config );
                $antivirus_built = 1;
            }
            return $antivirus;
        }
    );
    $application->helper(
        gp_attachment_storage => sub {
            my ($controller) = @_;

            $attachment_storage ||=
              GPForum::Service::Attachment::FilesystemStorage->new(
                root => $controller->gp_config->attachment_root );
            return $attachment_storage;
        }
    );
    $application->helper(
        gp_attachment_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Attachment::Store->new(
                clock       => $controller->gp_clock,
                id_service  => $controller->gp_id,
                readability => GPForum::Service::Forum::Readability->new(
                    schema => $controller->gp_schema
                ),
                schema => $controller->gp_schema,
            );
        }
    );
    $application->helper(
        gp_attachment_upload_pipeline => sub {
            my ($controller) = @_;

            return GPForum::Service::Attachment::UploadPipeline->new(
                antivirus      => $controller->gp_antivirus,
                intent_builder =>
                  GPForum::Service::Attachment::IntentBuilder->new(
                    clock      => $controller->gp_clock,
                    id_service => $controller->gp_id,
                  ),
                storage => $controller->gp_attachment_storage,
                store   => $controller->gp_attachment_store,
            );
        }
    );
    $application->helper(
        gp_attachment_delivery => sub {
            my ($controller) = @_;

            return GPForum::Service::Attachment::Delivery->new(
                storage => $controller->gp_attachment_storage,
                store   => $controller->gp_attachment_store,
            );
        }
    );
    $application->helper(
        gp_attachment_workflow => sub {
            my ($controller) = @_;

            return GPForum::Service::Attachment::Workflow->new(
                command_idempotency => $controller->gp_command_idempotency,
                delivery            => $controller->gp_attachment_delivery,
                logger              => $controller->app->log,
                pipeline    => $controller->gp_attachment_upload_pipeline,
                post_reader => $controller->gp_post_reader,
                store       => $controller->gp_attachment_store,
            );
        }
    );
    $application->helper(
        gp_media_processor => sub {
            my ($controller) = @_;

            return GPForum::Service::Attachment::MediaProcessor->new(
                storage => $controller->gp_attachment_storage,
                store   => $controller->gp_attachment_store,
            );
        }
    );

    return;
}

sub _register_community_helpers {
    my ($application) = @_;

    $application->helper(
        gp_bookmark_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Community::BookmarkStore->new(
                readability => GPForum::Service::Forum::Readability->new(
                    schema => $controller->gp_schema
                ),
                schema => $controller->gp_schema,
            );
        }
    );
    $application->helper(
        gp_community_workflow => sub {
            my ($controller) = @_;

            return GPForum::Service::Community::Workflow->new(
                bookmark_store      => $controller->gp_bookmark_store,
                command_idempotency => $controller->gp_command_idempotency,
                logger              => $controller->app->log,
                report_store        => $controller->gp_report_store,
                subscription_store  => $controller->gp_subscription_store,
            );
        }
    );
    $application->helper(
        gp_feed_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Community::FeedReader->new(
                readability => GPForum::Service::Forum::Readability->new(
                    schema => $controller->gp_schema
                ),
                schema => $controller->gp_schema,
            );
        }
    );
    $application->helper(
        gp_mention_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Community::MentionStore->new(
                notification_dispatcher =>
                  $controller->gp_notification_dispatcher,
                readability => GPForum::Service::Forum::Readability->new(
                    schema => $controller->gp_schema
                ),
                schema => $controller->gp_schema,
            );
        }
    );
    $application->helper(
        gp_mention_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Community::MentionReader->new(
                readability => GPForum::Service::Forum::Readability->new(
                    schema => $controller->gp_schema
                ),
                schema => $controller->gp_schema,
            );
        }
    );

    return;
}

sub _register_notification_helpers {
    my ($application) = @_;

    $application->helper(
        gp_subscription_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Notification::SubscriptionStore->new(
                schema => $controller->gp_schema );
        }
    );
    $application->helper(
        gp_notification_preference_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Notification::PreferenceStore->new(
                schema => $controller->gp_schema );
        }
    );
    $application->helper(
        gp_notification_dispatcher => sub {
            my ($controller) = @_;

            # ADR 0102: only recipients who can read the source are notified,
            # and the inbox shows only what they can still read.
            my $policy = GPForum::Service::Notification::RecipientPolicy->new(
                schema => $controller->gp_schema );

            return GPForum::Service::Notification::Dispatcher->new(
                permission_engine => $policy,
                preference_store  =>
                  $controller->gp_notification_preference_store,
                readability        => $policy,
                realtime_hub       => $controller->gp_realtime_hub,
                schema             => $controller->gp_schema,
                subscription_store => $controller->gp_subscription_store,
            );
        }
    );
    $application->helper(
        gp_notification_workflow => sub {
            my ($controller) = @_;

            return GPForum::Service::Notification::Workflow->new(
                command_idempotency => $controller->gp_command_idempotency,
                dispatcher          => $controller->gp_notification_dispatcher,
                logger              => $controller->app->log,
                preference_store    =>
                  $controller->gp_notification_preference_store,
            );
        }
    );
    $application->helper(
        gp_notification_renderer => sub {
            my ($controller) = @_;

            return GPForum::Service::Notification::Renderer->new(
                i18n => $controller->i18n_service );
        }
    );

    return;
}

sub _register_search_helpers {
    my ($application) = @_;

    $application->helper(
        gp_search_service => sub {
            my ($controller) = @_;

            return GPForum::Service::Search::Searcher->new(
                permission_engine =>
                  GPForum::Service::Search::PermissionEngine->new(
                    schema => $controller->gp_schema
                  ),
                schema => $controller->gp_schema,
            );
        }
    );

    return;
}

1;
