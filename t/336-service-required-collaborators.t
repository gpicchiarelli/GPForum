# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use lib 'lib';
use lib 't/lib';

use GPForum::X::Argument;
use Test::More;

our $VERSION = '0.001';

# The collaborators each identity, privacy, admin, moderation, community and
# notification service cannot work without (ADR 0118). A service built
# without one is refused where it is built, naming every one it lacks; one a
# single path reads -- a workflow's command log, a dispatcher's subscription
# store -- stays optional and is not listed here. Dropping a name from a
# requires line, or requiring an optional one, changes a row of this table.
my %REQUIRED = (
    'GPForum::Service::Admin::AuditReview'          => [qw(schema)],
    'GPForum::Service::Admin::Bootstrapper'         => [qw(schema)],
    'GPForum::Service::Admin::CategoryStore'        => [qw(schema)],
    'GPForum::Service::Admin::ConsoleReader'        => [qw(schema)],
    'GPForum::Service::Admin::Diagnostics'          => [qw(config)],
    'GPForum::Service::Admin::Maintenance'          => [qw(cache)],
    'GPForum::Service::Admin::PermissionGate'       => [qw(schema)],
    'GPForum::Service::Admin::PermissionReview'     => [qw(schema)],
    'GPForum::Service::Admin::RoleBindingStore'     => [qw(schema)],
    'GPForum::Service::Admin::RoleCatalog'          => [qw(schema)],
    'GPForum::Service::Community::BookmarkStore'    => [qw(schema)],
    'GPForum::Service::Community::FeedProjector'    => [qw(schema)],
    'GPForum::Service::Community::FeedReader'       => [qw(schema)],
    'GPForum::Service::Community::MentionReader'    => [qw(schema)],
    'GPForum::Service::Community::MentionStore'     => [qw(schema)],
    'GPForum::Service::Community::ReputationLedger' => [qw(schema)],
    'GPForum::Service::Community::Workflow'         =>
      [qw(bookmark_store report_store subscription_store)],
    'GPForum::Service::Identity::AccountStore' =>
      [qw(audit credential_store password schema session_store token_store)],
    'GPForum::Service::Identity::AuthStore' =>
      [qw(credential_store password schema session_store)],
    'GPForum::Service::Identity::CredentialStore'   => [qw(schema)],
    'GPForum::Service::Identity::PreferenceStore'   => [qw(schema)],
    'GPForum::Service::Identity::ProfileReader'     => [qw(schema)],
    'GPForum::Service::Identity::RegistrationStore' =>
      [qw(audit credential_store id_service schema)],
    'GPForum::Service::Identity::SessionStore'      => [qw(schema)],
    'GPForum::Service::Identity::TokenStore'        => [qw(schema)],
    'GPForum::Service::Identity::Workflow'          => [qw(registration store)],
    'GPForum::Service::Moderation::ActionStore'     => [qw(schema)],
    'GPForum::Service::Moderation::ReportStore'     => [qw(schema)],
    'GPForum::Service::Moderation::ReviewReader'    => [qw(schema)],
    'GPForum::Service::Moderation::SuspensionStore' => [qw(schema)],
    'GPForum::Service::Moderation::Workflow'        =>
      [qw(action_store report_store suspension_store)],
    'GPForum::Service::Notification::Dispatcher'        => [qw(schema)],
    'GPForum::Service::Notification::PreferenceStore'   => [qw(schema)],
    'GPForum::Service::Notification::SubscriptionStore' => [qw(schema)],
    'GPForum::Service::Notification::Workflow'          =>
      [qw(dispatcher preference_store)],
    'GPForum::Service::Privacy::DataRightsReview'   => [qw(schema)],
    'GPForum::Service::Privacy::DeletionWorkflow'   => [qw(schema)],
    'GPForum::Service::Privacy::ErasedExports'      => [qw(schema)],
    'GPForum::Service::Privacy::RetentionHoldStore' => [qw(schema)],
    'GPForum::Service::Privacy::Workflow'           =>
      [qw(deletion_workflow export_builder hold_store reviewer)],
);

sub _error_of ($code) {
    my $error;
    try {
        $code->();
    }
    catch ($caught) {
        $error = $caught;
    };

    return $error;
}

for my $class ( sort keys %REQUIRED ) {
    my @names = @{ $REQUIRED{$class} };
    ( my $file = "$class.pm" ) =~ s{::}{/}gmsx;
    require $file;

    is_deeply( [ sort $class->required_attributes ],
        \@names, "$class requires @names" );

    my $error = _error_of( sub { $class->new } );
    ok( GPForum::X::Argument->caught($error),
        "$class built without them is an argument error" );
    is(
        "$error",
        "$class requires " . join( q{, }, $class->required_attributes ),
        'naming every one it lacks'
    );

    # Each is only stored when the service is built, never called, so a
    # placeholder stands for it.
    my $built = _error_of(
        sub {
            $class->new( map { $_ => {} } @names );
        }
    );
    ok( !defined $built, "$class is built once it has them" );
}

done_testing();

1;
