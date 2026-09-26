# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Admin::Workflow;
use GPForum::Test::AdminWebServices;
use GPForum::Test::CommandIdempotency;
use Test::More;

our $VERSION = '0.001';

my $services = GPForum::Test::AdminWebServices->new;
my $workflow = GPForum::Service::Admin::Workflow->new(
    binding_store  => $services,
    category_store => $services,
    role_catalog   => $services,
);

my $missing_command = $workflow->create_role(
    {
        actor_user_id => 'admin-1',
        name          => 'space_admin',
    }
);
is( $missing_command->{status},
    'invalid', 'create_role rejects a missing command_id' );
is(
    $missing_command->{errors}{command_id},
    'command_id is required',
    'create_role names the missing command_id'
);

my $created = $workflow->create_role(
    {
        actor_user_id => 'admin-1',
        command_id    => 'role-1',
        description   => 'Scoped admin',
        name          => 'space_admin',
    }
);
ok( $created->{ok}, 'create_role succeeds when a name is present' );
is( $created->{stored}{name},
    'space_admin', 'create_role returns the stored role' );

my $missing_name = $workflow->create_role(
    {
        actor_user_id => 'admin-1',
        command_id    => 'role-missing-name',
        name          => q{},
    }
);
is( $missing_name->{status}, 'invalid', 'create_role rejects an empty name' );
is(
    $missing_name->{errors}{name},
    'name is required',
    'create_role names the missing field'
);

my $permission = $workflow->create_permission(
    {
        action        => 'view',
        actor_user_id => 'admin-1',
        command_id    => 'permission-1',
        name          => 'admin_console.view',
        resource_type => 'admin_console',
    }
);
ok( $permission->{ok},
    'create_permission succeeds when required fields are present' );

my $missing_permission = $workflow->attach_permission(
    {
        actor_user_id => 'admin-1',
        command_id    => 'attach-missing',
        permission_id => q{},
        role_id       => 'role-1',
    }
);
is( $missing_permission->{status},
    'invalid', 'attach_permission rejects an empty permission_id' );

my $attached = $workflow->attach_permission(
    {
        actor_user_id => 'admin-1',
        command_id    => 'attach-1',
        permission_id => 'permission-1',
        role_id       => 'role-1',
    }
);
ok( $attached->{ok}, 'attach_permission succeeds for known ids' );

my $bound = $workflow->bind_role(
    {
        actor_user_id => 'admin-1',
        command_id    => 'bind-1',
        resource_type => 'global',
        role_id       => 'role-1',
        user_id       => 'user-2',
    }
);
ok( $bound->{ok}, 'bind_role succeeds for a complete command' );

my $revoked = $workflow->revoke_binding(
    {
        actor_user_id => 'admin-1',
        binding_id    => 'binding-1',
        command_id    => 'revoke-1',
    }
);
ok( $revoked->{ok}, 'revoke_binding succeeds for a known binding' );

my $missing_binding = $workflow->revoke_binding(
    {
        actor_user_id => 'admin-1',
        binding_id    => 'missing',
        command_id    => 'revoke-missing',
    }
);
is( $missing_binding->{status},
    'not_found', 'revoke_binding maps a missing binding to not_found' );

my $category = $workflow->create_category(
    {
        actor_user_id => 'admin-1',
        command_id    => 'category-1',
        title         => 'General',
    }
);
ok( $category->{ok}, 'create_category succeeds when a title is present' );
is( $category->{stored}{title},
    'General', 'create_category returns the stored category' );

my $missing_title = $workflow->create_category(
    {
        actor_user_id => 'admin-1',
        command_id    => 'category-missing-title',
        title         => q{},
    }
);
is( $missing_title->{status},
    'invalid', 'create_category rejects an empty title' );
is(
    $missing_title->{errors}{title},
    'title is required',
    'create_category names the missing field'
);

my $bad_visibility = $workflow->create_category(
    {
        actor_user_id => 'admin-1',
        command_id    => 'category-bad-visibility',
        title         => 'Hidden',
        visibility    => 'secret',
    }
);
is( $bad_visibility->{status},
    'invalid', 'create_category rejects an unknown visibility' );

my $updated = $workflow->update_category(
    {
        actor_user_id => 'admin-1',
        category_id   => 'category-1',
        command_id    => 'category-update-1',
        title         => 'Updated',
    }
);
ok( $updated->{ok}, 'update_category succeeds for a known category' );

my $missing_category = $workflow->update_category(
    {
        actor_user_id => 'admin-1',
        category_id   => 'missing',
        command_id    => 'category-update-missing',
    }
);
is( $missing_category->{status},
    'not_found', 'update_category maps a missing category to not_found' );

my $idempotency = GPForum::Test::CommandIdempotency->new;
my $commanded   = GPForum::Service::Admin::Workflow->new(
    binding_store       => $services,
    category_store      => $services,
    command_idempotency => $idempotency,
    role_catalog        => $services,
);
_replay_admin(
    {
        commanded    => $commanded,
        command_type => 'admin.role_create',
        counter      => 'role_creates',
        idempotency  => $idempotency,
        input        => {
            actor_user_id => 'admin-1',
            command_id    => 'role-replay-1',
            name          => 'space_admin',
        },
        method  => 'create_role',
        request => {
            actor_user_id => 'admin-1',
            description   => undef,
            name          => 'space_admin',
        },
        services => $services,
    }
);
_replay_admin(
    {
        commanded    => $commanded,
        command_type => 'admin.category_create',
        counter      => 'category_creates',
        idempotency  => $idempotency,
        input        => {
            actor_user_id => 'admin-1',
            command_id    => 'category-replay-1',
            title         => 'General',
        },
        method  => 'create_category',
        request => {
            actor_user_id => 'admin-1',
            category_id   => q{},
            description   => undef,
            position      => undef,
            slug          => undef,
            space_id      => undef,
            title         => 'General',
            visibility    => undef,
        },
        services => $services,
    }
);

done_testing();

sub _store_writes {
    my ( $store, $counter ) = @_;

    return scalar @{ $store->$counter };
}

sub _replay_admin {
    my ($job) = @_;

    my $method       = $job->{method};
    my $write_issued = $job->{commanded}->$method( $job->{input} );
    ok( $write_issued->{ok}, "$method records a command" );
    is( $job->{idempotency}->last_input->{command_type},
        $job->{command_type}, "$method uses $job->{command_type}" );
    is_deeply( $job->{idempotency}->last_input->{request},
        $job->{request}, "$method command log stores actor and target" );
    my $write_count    = _store_writes( $job->{services}, $job->{counter} );
    my $write_replayed = GPForum::Service::Admin::Workflow->new(
        binding_store       => $job->{services},
        category_store      => $job->{services},
        command_idempotency => GPForum::Test::CommandIdempotency->new(
            replay_response => $write_issued,
        ),
        role_catalog => $job->{services},
    )->$method( $job->{input} );
    is_deeply( $write_replayed, $write_issued,
        "$method replays the recorded result" );
    is( _store_writes( $job->{services}, $job->{counter} ),
        $write_count, "$method replay does not persist twice" );
    my $write_conflict = GPForum::Service::Admin::Workflow->new(
        binding_store       => $job->{services},
        category_store      => $job->{services},
        command_idempotency => GPForum::Test::CommandIdempotency->new(
            conflict => 1,
        ),
        role_catalog => $job->{services},
    )->$method( $job->{input} );
    is( $write_conflict->{status},
        'conflict', "$method rejects a reused command_id for another request" );

    return;
}

1;
