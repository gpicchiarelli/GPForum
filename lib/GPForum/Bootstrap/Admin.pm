# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Bootstrap::Admin;

use v5.40;

use GPForum::Service::Admin::AuditReview;
use GPForum::Service::Admin::CategoryStore;
use GPForum::Service::Admin::ConsoleReader;
use GPForum::Service::Admin::Diagnostics;
use GPForum::Service::Admin::Maintenance;
use GPForum::Service::Admin::PermissionGate;
use GPForum::Service::Admin::PermissionReview;
use GPForum::Service::Admin::RoleBindingStore;
use GPForum::Service::Admin::RoleCatalog;
use GPForum::Service::Admin::Settings;
use GPForum::Service::Admin::Workflow;
use GPForum::Service::Outbox::DeadLetterReplay;

our $VERSION = '0.001';

sub register {
    my ( undef, %input ) = @_;

    my $application = $input{application};

    $application->helper(
        gp_permission_gate => sub {
            my ($controller) = @_;

            return GPForum::Service::Admin::PermissionGate->new(
                schema => $controller->gp_schema );
        }
    );
    $application->helper(
        gp_role_catalog => sub {
            my ($controller) = @_;

            return GPForum::Service::Admin::RoleCatalog->new(
                schema => $controller->gp_schema );
        }
    );
    $application->helper(
        gp_role_binding_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Admin::RoleBindingStore->new(
                schema => $controller->gp_schema );
        }
    );
    $application->helper(
        gp_category_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Admin::CategoryStore->new(
                schema => $controller->gp_schema );
        }
    );
    $application->helper(
        gp_permission_review => sub {
            my ($controller) = @_;

            return GPForum::Service::Admin::PermissionReview->new(
                schema => $controller->gp_schema );
        }
    );
    $application->helper(
        gp_admin_audit_review => sub {
            my ($controller) = @_;

            return GPForum::Service::Admin::AuditReview->new(
                schema => $controller->gp_schema );
        }
    );
    $application->helper(
        gp_admin_console_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Admin::ConsoleReader->new(
                metrics_snapshot => $controller->gp_metrics_snapshot,
                readiness        => $controller->gp_readiness,
                schema           => $controller->gp_schema,
            );
        }
    );
    $application->helper(
        gp_dead_letter_replay => sub {
            my ($controller) = @_;

            return GPForum::Service::Outbox::DeadLetterReplay->new(
                schema => $controller->gp_schema );
        }
    );
    $application->helper(
        gp_admin_maintenance => sub {
            my ($controller) = @_;

            return GPForum::Service::Admin::Maintenance->new(
                cache  => $controller->gp_local_cache,
                schema => $controller->gp_schema,
            );
        }
    );
    $application->helper(
        gp_admin_settings => sub {
            my ($controller) = @_;

            return GPForum::Service::Admin::Settings->new(
                config => $controller->gp_config );
        }
    );
    $application->helper(
        gp_admin_diagnostics => sub {
            my ($controller) = @_;

            return GPForum::Service::Admin::Diagnostics->new(
                accounts     => $controller->gp_admin_console_reader,
                antivirus    => $controller->gp_antivirus,
                audit_review => $controller->gp_admin_audit_review,
                config       => $controller->gp_config,
                id_service   => $controller->gp_id,
                schema       => $controller->gp_schema,
                settings     => $controller->gp_admin_settings,
            );
        }
    );
    $application->helper(
        gp_admin_workflow => sub {
            my ($controller) = @_;

            return GPForum::Service::Admin::Workflow->new(
                binding_store       => $controller->gp_role_binding_store,
                category_store      => $controller->gp_category_store,
                command_idempotency => $controller->gp_command_idempotency,
                dead_letter_replay  => $controller->gp_dead_letter_replay,
                diagnostics         => $controller->gp_admin_diagnostics,
                logger              => $controller->app->log,
                maintenance         => $controller->gp_admin_maintenance,
                role_catalog        => $controller->gp_role_catalog,
            );
        }
    );

    return;
}

1;
