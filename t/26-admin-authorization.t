package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Admin::PermissionGate;
use GPForum::Service::Admin::PermissionReview;
use GPForum::Service::Admin::RoleBindingStore;
use GPForum::Service::Admin::RoleCatalog;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::ModerationResultSet;
use GPForum::Test::ModerationSchema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS      => 45;
const my $ROLE_LIMIT          => 10;
const my $REVIEW_LIMIT        => 20;
const my $CREATED_ROLES       => 1;
const my $CREATED_PERMISSIONS => 1;
const my $CREATED_ROLE_PERMS  => 1;
const my $CREATED_BINDINGS    => 1;
const my $CREATED_AUDIT_ROWS  => 2;
const my $FIRST_AUDIT_INDEX   => 0;
const my $SECOND_AUDIT_INDEX  => 1;

plan tests => $EXPECTED_TESTS;

my $roles            = GPForum::Test::ModerationResultSet->new;
my $permissions      = GPForum::Test::ModerationResultSet->new;
my $role_permissions = GPForum::Test::ModerationResultSet->new;
my $role_bindings    = GPForum::Test::ModerationResultSet->new;
my $audit_log        = GPForum::Test::ModerationResultSet->new;
my $schema           = GPForum::Test::ModerationSchema->new(
    resultsets => {
        Role           => $roles,
        Permission     => $permissions,
        RolePermission => $role_permissions,
        RoleBinding    => $role_bindings,
        AuditLog       => $audit_log,
    },
);
my $clock = GPForum::Test::FixedClock->new;

my $catalog = GPForum::Service::Admin::RoleCatalog->new(
    schema     => $schema,
    clock      => $clock,
    id_service => GPForum::Test::Id->new,
);
my $role = $catalog->create_role(
    {
        name        => 'space_moderator',
        description => 'Scoped moderation authority',
    }
);

is( $role->{role_id}, 'generated-1',     'role id is generated' );
is( $role->{name},    'space_moderator', 'role stores name' );
is(
    $role->{description},
    'Scoped moderation authority',
    'role stores description'
);
is( $role->{created_at}, '2026-05-23T12:00:00Z', 'role stores creation time' );
is( scalar @{ $roles->created }, $CREATED_ROLES, 'role row is inserted' );

my $permission = $catalog->create_permission(
    {
        name          => 'report.view_queue',
        resource_type => 'report',
        action        => 'view_queue',
    }
);

is( $permission->{permission_id}, 'generated-2', 'permission id is generated' );
is( $permission->{name}, 'report.view_queue',    'permission stores name' );
is( $permission->{resource_type}, 'report', 'permission stores resource type' );
is( $permission->{action},        'view_queue', 'permission stores action' );
is( scalar @{ $permissions->created },
    $CREATED_PERMISSIONS, 'permission row is inserted' );

my $role_permission = $catalog->attach_permission(
    {
        role_id       => 'generated-1',
        permission_id => 'generated-2',
    }
);
is( $role_permission->{role_id}, 'generated-1', 'role permission stores role' );
is( $role_permission->{permission_id},
    'generated-2', 'role permission stores permission' );
is( scalar @{ $role_permissions->created },
    $CREATED_ROLE_PERMS, 'role permission row is inserted' );

my $listed_roles = $catalog->list_roles( { limit => $ROLE_LIMIT } );
is( scalar @{$listed_roles},    $CREATED_ROLES, 'roles can be listed' );
is( $roles->last_attrs->{rows}, $ROLE_LIMIT,    'role listing applies limit' );

my $listed_permissions = $catalog->list_permissions( { limit => $ROLE_LIMIT } );
is(
    scalar @{$listed_permissions},
    $CREATED_PERMISSIONS,
    'permissions can be listed'
);
is( $permissions->last_attrs->{rows},
    $ROLE_LIMIT, 'permission listing applies limit' );

my $binding_store = GPForum::Service::Admin::RoleBindingStore->new(
    schema     => $schema,
    clock      => $clock,
    id_service => GPForum::Test::Id->new,
);
my $bound = $binding_store->bind_role(
    {
        actor_user_id => 'admin-1',
        user_id       => 'moderator-1',
        role_id       => 'generated-1',
        resource_type => 'space',
        resource_id   => 'space-1',
        space_id      => 'space-1',
    }
);

ok( $bound->{ok}, 'role binding succeeds' );
is( $bound->{binding}{binding_id},
    'generated-1', 'role binding id is generated' );
is( $bound->{binding}{user_id},       'moderator-1', 'binding stores user' );
is( $bound->{binding}{role_id},       'generated-1', 'binding stores role' );
is( $bound->{binding}{resource_type}, 'space', 'binding stores resource type' );
is( $bound->{binding}{resource_id},   'space-1', 'binding stores resource id' );
is( $bound->{binding}{created_by_user_id},
    'admin-1', 'binding stores creator' );
is( scalar @{ $role_bindings->created },
    $CREATED_BINDINGS, 'role binding row is inserted' );
is( scalar @{ $audit_log->created }, 1, 'role binding creation is audited' );
is( $audit_log->created->[$FIRST_AUDIT_INDEX]{action},
    'role_binding.created', 'audit records binding creation' );

my $revoked = $binding_store->revoke_binding( 'generated-1', 'admin-2' );
is( $revoked->{binding_id}, 'generated-1', 'revoke returns binding id' );
is( $revoked->{revoked_at}, '2026-05-23T12:00:00Z', 'revoke stores timestamp' );
is( $role_bindings->find('generated-1')->get_column('revoked_at'),
    '2026-05-23T12:00:00Z', 'binding row is revoked' );
is( scalar @{ $audit_log->created },
    $CREATED_AUDIT_ROWS, 'role binding revocation is audited' );
is( $audit_log->created->[$SECOND_AUDIT_INDEX]{action},
    'role_binding.revoked', 'audit records binding revocation' );
is( $binding_store->revoke_binding( 'missing-binding', 'admin-2' ),
    undef, 'missing role binding cannot be revoked' );

my $review =
  GPForum::Service::Admin::PermissionReview->new( schema => $schema );
my $user_roles =
  $review->roles_for_user( 'moderator-1', { limit => $REVIEW_LIMIT } );
is( scalar @{$user_roles}, $CREATED_BINDINGS, 'user roles can be reviewed' );
is( $role_bindings->last_query->{user_id},
    'moderator-1', 'role review filters user' );
is( $role_bindings->last_query->{revoked_at},
    undef, 'role review filters revoked bindings' );
is( $role_bindings->last_attrs->{rows},
    $REVIEW_LIMIT, 'role review applies limit' );

my $role_perms =
  $review->permissions_for_role( 'generated-1', { limit => $REVIEW_LIMIT } );
is( scalar @{$role_perms},
    $CREATED_ROLE_PERMS, 'role permissions can be reviewed' );
is( $role_permissions->last_query->{role_id},
    'generated-1', 'permission review filters role' );
is( $role_permissions->last_attrs->{rows},
    $REVIEW_LIMIT, 'permission review applies limit' );

my $permission_gate =
  GPForum::Service::Admin::PermissionGate->new( schema => $schema );
ok(
    $permission_gate->allowed(
        { user_id       => 'moderator-1' },
        { resource_type => 'report', action => 'view_queue' },
    ),
    'permission gate allows matching role binding'
);
is( $role_bindings->last_query->{'me.user_id'},
    'moderator-1', 'permission gate filters user' );
is( $role_bindings->last_query->{'permission.resource_type'},
    'report', 'permission gate filters resource type' );
is( $role_bindings->last_query->{'permission.action'},
    'view_queue', 'permission gate filters action' );

my $empty_gate = GPForum::Service::Admin::PermissionGate->new(
    schema => GPForum::Test::ModerationSchema->new(
        resultsets => {
            RoleBinding => GPForum::Test::ModerationResultSet->new,
        },
    ),
);
ok(
    !$empty_gate->allowed(
        { user_id       => 'missing' },
        { resource_type => 'report', action => 'view_queue' }
    ),
    'permission gate denies without role binding'
);

1;
