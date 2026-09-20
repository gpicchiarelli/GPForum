package GPForum::Bootstrap::Moderation;

use strict;
use warnings;

use GPForum::Service::Moderation::ActionStore;
use GPForum::Service::Moderation::ReportStore;
use GPForum::Service::Moderation::ReviewReader;
use GPForum::Service::Moderation::SuspensionStore;
use GPForum::Service::Moderation::Workflow;

our $VERSION = '0.001';

sub register {
    my ( undef, %input ) = @_;

    my $application = $input{application};

    $application->helper(
        gp_report_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Moderation::ReportStore->new(
                schema => $controller->gp_schema );
        }
    );
    $application->helper(
        gp_moderation_action_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Moderation::ActionStore->new(
                schema => $controller->gp_schema );
        }
    );
    $application->helper(
        gp_suspension_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Moderation::SuspensionStore->new(
                schema => $controller->gp_schema );
        }
    );
    $application->helper(
        gp_moderation_review_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Moderation::ReviewReader->new(
                schema => $controller->gp_schema );
        }
    );
    $application->helper(
        gp_moderation_workflow => sub {
            my ($controller) = @_;

            return GPForum::Service::Moderation::Workflow->new(
                action_store        => $controller->gp_moderation_action_store,
                command_idempotency => $controller->gp_command_idempotency,
                logger              => $controller->app->log,
                report_store        => $controller->gp_report_store,
                suspension_store    => $controller->gp_suspension_store,
            );
        }
    );

    return;
}

1;
