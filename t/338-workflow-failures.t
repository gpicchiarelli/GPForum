# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Admin::Workflow;
use GPForum::Service::Community::Workflow;
use GPForum::Service::Identity::Workflow;
use GPForum::Service::Moderation::Workflow;
use GPForum::Service::Notification::Workflow;
use GPForum::Service::Privacy::Workflow;
use GPForum::Test::OfflineCommandLog;
use GPForum::Test::OfflineStore;
use GPForum::Test::QuietLog;
use Test::More;

our $VERSION = '0.001';

# A write under a command id first claims the id in the command log. When
# the log cannot be reached, each workflow answers that the command failed
# and logs why; nothing dies past it, and the store is never asked. The
# collaborators are placeholders a call on would die.
my @CASES = (
    {
        class    => 'GPForum::Service::Admin::Workflow',
        input    => { actor_user_id => 'admin-1', name => 'space_admin' },
        logged   => 'admin write failed',
        method   => 'create_role',
        services => [qw(role_catalog)],
    },
    {
        class => 'GPForum::Service::Community::Workflow',
        input => {
            target_id   => 'thread-1',
            target_type => 'thread',
            user_id     => 'user-1',
        },
        logged   => 'community command log failed',
        method   => 'save_bookmark',
        services => [qw(bookmark_store report_store subscription_store)],
    },
    {
        class    => 'GPForum::Service::Identity::Workflow',
        input    => { identifier => 'member@example.test' },
        logged   => 'identity command log failed',
        method   => 'request_password_reset',
        services => [qw(registration store)],
    },
    {
        class => 'GPForum::Service::Moderation::Workflow',
        input => {
            actor_user_id => 'moderator-1',
            post_id       => 'post-1',
            reason        => 'spam',
        },
        logged   => 'moderation command log failed',
        method   => 'hide_post',
        services => [qw(action_store report_store suspension_store)],
    },
    {
        class    => 'GPForum::Service::Notification::Workflow',
        input    => { preferences => [], user_id => 'user-1' },
        logged   => 'notification command log failed',
        method   => 'set_preferences',
        services => [qw(dispatcher preference_store)],
    },
    {
        class    => 'GPForum::Service::Privacy::Workflow',
        input    => { user_id => 'user-1' },
        logged   => 'privacy command log failed',
        method   => 'request_export',
        services => [qw(deletion_workflow export_builder hold_store reviewer)],
    },
);

for my $case (@CASES) {
    my $log    = GPForum::Test::QuietLog->new;
    my $result = _write(
        $case,
        command_idempotency => GPForum::Test::OfflineCommandLog->new,
        logger              => $log,
        map { $_ => {} } @{ $case->{services} },
    );
    is( $result->{status}, q{failed},
        "$case->{class} answers that the command failed" );
    like(
        $log->errors->[0] // q{},
        qr/\A \Q$case->{logged}\E: [ ] command [ ] log [ ] offline/msx,
        'logging why'
    );
}

# Without a command log the store runs on its own, and its exception is
# caught by the workflow: the command fails, and the log says why.
my %CASE        = map { $_->{class} => $_ } @CASES;
my @STORE_CASES = (
    [qw(Admin role_catalog)],
    [qw(Community bookmark_store)],
    [qw(Identity store)],
    [qw(Moderation action_store)],
    [qw(Notification preference_store)],
    [
        qw(Privacy deletion_workflow request_deletion),
        { reason => q{leaving}, user_id => q{user-1} },
    ],
);
for my $store_case (@STORE_CASES) {
    my ( $area, $offline, $method, $input ) = @{$store_case};
    my $case = $CASE{"GPForum::Service::${area}::Workflow"};
    if ($method) {
        $case = { %{$case}, input => $input, method => $method };
    }
    my $logged = lc($area) . q{ write failed};
    my $log    = GPForum::Test::QuietLog->new;
    my $result = _write(
        $case,
        logger => $log,
        ( map { $_ => {} } @{ $case->{services} } ),
        $offline => GPForum::Test::OfflineStore->new,
    );
    is( $result->{status}, q{failed},
        "$case->{class} answers that a store that died failed" );
    like(
        $log->errors->[0] // q{},
        qr/\A \Q$logged\E: [ ] store [ ] offline/msx,
        'logging why'
    );
}

done_testing();

# The workflow's answer to the case's write; dying past the workflow fails
# the test.
sub _write ( $case, %services ) {
    my $workflow = $case->{class}->new(%services);
    my $method   = $case->{method};
    my ( $result, $error );
    try {
        $result =
          $workflow->$method( { %{ $case->{input} }, command_id => q{cmd-1} } );
    }
    catch ($caught) {
        $error = $caught;
    };
    ok( !defined $error, "$case->{class} $method dies no further" )
      or diag $error;

    return $result // {};
}

1;
