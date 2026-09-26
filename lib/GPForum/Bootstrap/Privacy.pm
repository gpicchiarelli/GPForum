# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Bootstrap::Privacy;

use strict;
use warnings;
use feature 'signatures';

use GPForum::Service::Portability::ExportBundleBuilder;
use GPForum::Service::Privacy::DataRightsReview;
use GPForum::Service::Privacy::DeletionWorkflow;
use GPForum::Service::Privacy::RetentionHoldStore;
use GPForum::Service::Privacy::Workflow;

our $VERSION = '0.001';

sub register {
    my ( undef, %input ) = @_;

    my $application = $input{application};

    $application->helper(
        gp_export_bundle_builder => sub {
            my ($controller) = @_;

            return GPForum::Service::Portability::ExportBundleBuilder->new(
                clock      => $controller->gp_clock,
                id_service => $controller->gp_id,
                schema     => $controller->gp_schema,
            );
        }
    );
    $application->helper(
        gp_deletion_workflow => sub {
            my ($controller) = @_;

            return GPForum::Service::Privacy::DeletionWorkflow->new(
                clock      => $controller->gp_clock,
                id_service => $controller->gp_id,
                schema     => $controller->gp_schema,
            );
        }
    );
    $application->helper(
        gp_data_rights_review => sub {
            my ($controller) = @_;

            return GPForum::Service::Privacy::DataRightsReview->new(
                schema => $controller->gp_schema );
        }
    );
    $application->helper(
        gp_retention_hold_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Privacy::RetentionHoldStore->new(
                clock      => $controller->gp_clock,
                id_service => $controller->gp_id,
                schema     => $controller->gp_schema,
            );
        }
    );
    $application->helper(
        gp_privacy_workflow => sub {
            my ($controller) = @_;

            return GPForum::Service::Privacy::Workflow->new(
                command_idempotency => $controller->gp_command_idempotency,
                deletion_workflow   => $controller->gp_deletion_workflow,
                export_builder      => $controller->gp_export_bundle_builder,
                hold_store          => $controller->gp_retention_hold_store,
                logger              => $controller->app->log,
                reviewer            => $controller->gp_data_rights_review,
            );
        }
    );

    return;
}

1;
