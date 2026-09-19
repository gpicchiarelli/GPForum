package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Admin::Workflow;
use GPForum::Test::AdminWebServices;
use Test::More;

our $VERSION = '0.001';

my $services = GPForum::Test::AdminWebServices->new;
my $workflow = GPForum::Service::Admin::Workflow->new(
    binding_store  => $services,
    category_store => $services,
    role_catalog   => $services,
);

my $created = $workflow->create_role(
    {
        actor_user_id => 'admin-1',
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
        name          => 'admin_console.view',
        resource_type => 'admin_console',
    }
);
ok( $permission->{ok},
    'create_permission succeeds when required fields are present' );

my $missing_permission = $workflow->attach_permission(
    {
        actor_user_id => 'admin-1',
        permission_id => q{},
        role_id       => 'role-1',
    }
);
is( $missing_permission->{status},
    'invalid', 'attach_permission rejects an empty permission_id' );

my $attached = $workflow->attach_permission(
    {
        actor_user_id => 'admin-1',
        permission_id => 'permission-1',
        role_id       => 'role-1',
    }
);
ok( $attached->{ok}, 'attach_permission succeeds for known ids' );

my $bound = $workflow->bind_role(
    {
        actor_user_id => 'admin-1',
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
    }
);
ok( $revoked->{ok}, 'revoke_binding succeeds for a known binding' );

my $missing_binding = $workflow->revoke_binding(
    {
        actor_user_id => 'admin-1',
        binding_id    => 'missing',
    }
);
is( $missing_binding->{status},
    'not_found', 'revoke_binding maps a missing binding to not_found' );

my $category = $workflow->create_category(
    {
        actor_user_id => 'admin-1',
        title         => 'General',
    }
);
ok( $category->{ok}, 'create_category succeeds when a title is present' );
is( $category->{stored}{title},
    'General', 'create_category returns the stored category' );

my $missing_title = $workflow->create_category(
    {
        actor_user_id => 'admin-1',
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
        title         => 'Updated',
    }
);
ok( $updated->{ok}, 'update_category succeeds for a known category' );

my $missing_category = $workflow->update_category(
    {
        actor_user_id => 'admin-1',
        category_id   => 'missing',
    }
);
is( $missing_category->{status},
    'not_found', 'update_category maps a missing category to not_found' );

done_testing();

1;
