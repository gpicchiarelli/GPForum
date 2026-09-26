# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Admin::ConsoleReader;
use GPForum::Service::Admin::PermissionGate;
use GPForum::Service::Admin::PermissionReview;
use GPForum::Service::Admin::RoleBindingStore;
use GPForum::Service::Admin::RoleCatalog;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::ModerationResultSet;
use GPForum::Test::ModerationSchema;

our $VERSION = '0.001';

const my $ROLE_LIMIT          => 10;
const my $REVIEW_LIMIT        => 20;
const my $CREATED_ROLES       => 1;
const my $CREATED_PERMISSIONS => 1;
const my $CREATED_ROLE_PERMS  => 1;
const my $CREATED_BINDINGS    => 1;
const my $CATALOG_AUDIT_ROWS  => 3;
const my $BINDING_AUDIT_ROWS  => 4;
const my $REVOKE_AUDIT_ROWS   => 5;

my $roles       = GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $permissions = GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $role_permissions =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $role_bindings = GPForum::Test::ModerationResultSet->new;
my $audit_log     = GPForum::Test::ModerationResultSet->new;
my $users         = GPForum::Test::ModerationResultSet->new;
my $reports       = GPForum::Test::ModerationResultSet->new;
my $outbox        = GPForum::Test::ModerationResultSet->new;
my $dead_letters  = GPForum::Test::ModerationResultSet->new;
my $schema        = GPForum::Test::ModerationSchema->new(
    resultsets => {
        DeadLetter     => $dead_letters,
        OutboxMessage  => $outbox,
        Report         => $reports,
        Role           => $roles,
        Permission     => $permissions,
        RolePermission => $role_permissions,
        RoleBinding    => $role_bindings,
        AuditLog       => $audit_log,
        User           => $users,
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

is( $permission->{permission_id}, 'generated-4', 'permission id is generated' );
is( $permission->{name}, 'report.view_queue',    'permission stores name' );
is( $permission->{resource_type}, 'report', 'permission stores resource type' );
is( $permission->{action},        'view_queue', 'permission stores action' );
is( scalar @{ $permissions->created },
    $CREATED_PERMISSIONS, 'permission row is inserted' );

my $role_permission = $catalog->attach_permission(
    {
        role_id       => 'generated-1',
        permission_id => 'generated-4',
    }
);
is( $role_permission->{role_id}, 'generated-1', 'role permission stores role' );
is( $role_permission->{permission_id},
    'generated-4', 'role permission stores permission' );
is( scalar @{ $role_permissions->created },
    $CREATED_ROLE_PERMS, 'role permission row is inserted' );
is( scalar @{ $audit_log->created },
    $CATALOG_AUDIT_ROWS, 'role catalog writes audit for every mutation' );
is( $audit_log->created->[0]{action},
    'role.created', 'audit records role creation' );
is( $audit_log->created->[1]{action},
    'permission.created', 'audit records permission creation' );
is( $audit_log->created->[2]{action},
    'role_permission.attached', 'audit records permission attachment' );

ok(
    $catalog->create_role(
        {
            name        => 'space_moderator',
            description => 'Scoped moderation authority',
        }
    )->{idempotent},
    'duplicate role creation is idempotent'
);
ok(
    $catalog->create_permission(
        {
            name          => 'report.view_queue',
            resource_type => 'report',
            action        => 'view_queue',
        }
    )->{idempotent},
    'duplicate permission creation is idempotent'
);
ok(
    $catalog->attach_permission(
        {
            role_id       => 'generated-1',
            permission_id => 'generated-4',
        }
    )->{idempotent},
    'duplicate role permission attachment is idempotent'
);
is( scalar @{ $roles->created },
    $CREATED_ROLES, 'idempotent role create avoids duplicate rows' );
is( scalar @{ $permissions->created },
    $CREATED_PERMISSIONS,
    'idempotent permission create avoids duplicate rows' );
is( scalar @{ $role_permissions->created },
    $CREATED_ROLE_PERMS, 'idempotent permission attach avoids duplicate rows' );
is( scalar @{ $audit_log->created },
    $CATALOG_AUDIT_ROWS, 'idempotent catalog mutations avoid duplicate audit' );

$roles->skip_search(1);
ok(
    $catalog->create_role(
        {
            name        => 'space_moderator',
            description => 'concurrent role after lookup miss',
        }
    )->{idempotent},
    'unique role race reuses the existing name'
);
is( scalar @{ $roles->created },
    $CREATED_ROLES, 'unique role race does not insert a second role' );
is( scalar @{ $audit_log->created },
    $CATALOG_AUDIT_ROWS, 'unique role race does not write a second audit' );

$permissions->skip_search(1);
ok(
    $catalog->create_permission(
        {
            action        => 'view_queue',
            name          => 'report.view_queue',
            resource_type => 'report',
        }
    )->{idempotent},
    'unique permission race reuses the existing resource action'
);
is( scalar @{ $permissions->created },
    $CREATED_PERMISSIONS,
    'unique permission race does not insert a second permission' );
is( scalar @{ $audit_log->created },
    $CATALOG_AUDIT_ROWS,
    'unique permission race does not write a second audit' );

$role_permissions->skip_search(1);
ok(
    $catalog->attach_permission(
        {
            permission_id => 'generated-4',
            role_id       => 'generated-1',
        }
    )->{idempotent},
    'unique attach race reuses the existing grant'
);
is( scalar @{ $role_permissions->created },
    $CREATED_ROLE_PERMS, 'unique attach race does not insert a second grant' );
is( scalar @{ $audit_log->created },
    $CATALOG_AUDIT_ROWS, 'unique attach race does not write a second audit' );

my $role_pk_roles =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $role_pk_audit = GPForum::Test::ModerationResultSet->new;
$role_pk_roles->create(
    {
        name    => 'other-role',
        role_id => 'generated-1',
    }
);
my $role_pk_catalog = GPForum::Service::Admin::RoleCatalog->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog => $role_pk_audit,
            Role     => $role_pk_roles,
        },
    ),
);
my $role_pk = $role_pk_catalog->create_role(
    {
        description => 'Scoped moderation authority',
        name        => 'space_moderator',
    }
);
ok( !$role_pk->{idempotent}, 'unique role id collision remints and creates' );
is( $role_pk->{role_id}, 'generated-2',
    'unique role id collision remints the id' );
is( $role_pk->{name}, 'space_moderator',
    'unique role id collision keeps this role name' );
is(
    $role_pk->{description},
    'Scoped moderation authority',
    'unique role id collision keeps this role description'
);

my $role_leftover_roles =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $role_leftover_audit = GPForum::Test::ModerationResultSet->new;
$role_leftover_roles->create(
    {
        description => 'Scoped moderation authority',
        name        => 'space_moderator',
        role_id     => 'generated-1',
    }
);
$role_leftover_roles->skip_search(1);
my $role_leftover_catalog = GPForum::Service::Admin::RoleCatalog->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog => $role_leftover_audit,
            Role     => $role_leftover_roles,
        },
    ),
);
my $role_leftover = $role_leftover_catalog->create_role(
    {
        description => 'Scoped moderation authority',
        name        => 'space_moderator',
    }
);
ok( $role_leftover->{idempotent}, 'leftover role id race reuses this role' );
is( $role_leftover->{role_id},
    'generated-1', 'leftover role id race keeps this role' );
is( $role_leftover->{name},
    'space_moderator', 'leftover role id race keeps this role name' );
is( scalar @{ $role_leftover_roles->created },
    1, 'leftover role id race does not insert a second role' );
is( scalar @{ $role_leftover_audit->created },
    1, 'leftover role id race inserts the missing audit' );

my $permission_pk_permissions =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $permission_pk_audit = GPForum::Test::ModerationResultSet->new;
$permission_pk_permissions->create(
    {
        action        => 'other_action',
        name          => 'other.permission',
        permission_id => 'generated-1',
        resource_type => 'other',
    }
);
my $permission_pk_catalog = GPForum::Service::Admin::RoleCatalog->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog   => $permission_pk_audit,
            Permission => $permission_pk_permissions,
        },
    ),
);
my $permission_pk = $permission_pk_catalog->create_permission(
    {
        action        => 'view_queue',
        name          => 'report.view_queue',
        resource_type => 'report',
    }
);
ok( !$permission_pk->{idempotent},
    'unique permission id collision remints and creates' );
is( $permission_pk->{permission_id},
    'generated-2', 'unique permission id collision remints the id' );
is( $permission_pk->{name},
    'report.view_queue',
    'unique permission id collision keeps this permission name' );
is( $permission_pk->{resource_type},
    'report', 'unique permission id collision keeps this resource type' );

my $permission_leftover_permissions =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $permission_leftover_audit = GPForum::Test::ModerationResultSet->new;
$permission_leftover_permissions->create(
    {
        action        => 'view_queue',
        name          => 'report.view_queue',
        permission_id => 'generated-1',
        resource_type => 'report',
    }
);
$permission_leftover_permissions->skip_search(1);
my $permission_leftover_catalog = GPForum::Service::Admin::RoleCatalog->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog   => $permission_leftover_audit,
            Permission => $permission_leftover_permissions,
        },
    ),
);
my $permission_leftover = $permission_leftover_catalog->create_permission(
    {
        action        => 'view_queue',
        name          => 'report.view_queue',
        resource_type => 'report',
    }
);
ok( $permission_leftover->{idempotent},
    'leftover permission id race reuses this permission' );
is( $permission_leftover->{permission_id},
    'generated-1', 'leftover permission id race keeps this permission' );
is( $permission_leftover->{name},
    'report.view_queue',
    'leftover permission id race keeps this permission name' );
is( scalar @{ $permission_leftover_permissions->created },
    1, 'leftover permission id race does not insert a second permission' );
is( scalar @{ $permission_leftover_audit->created },
    1, 'leftover permission id race inserts the missing audit' );

my $attach_leftover_grants =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $attach_leftover_audit = GPForum::Test::ModerationResultSet->new;
$attach_leftover_grants->create(
    {
        permission_id => 'generated-4',
        role_id       => 'generated-1',
    }
);
$attach_leftover_grants->skip_search(1);
my $attach_leftover_catalog = GPForum::Service::Admin::RoleCatalog->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog       => $attach_leftover_audit,
            RolePermission => $attach_leftover_grants,
        },
    ),
);
my $attach_leftover = $attach_leftover_catalog->attach_permission(
    {
        permission_id => 'generated-4',
        role_id       => 'generated-1',
    }
);
ok( $attach_leftover->{idempotent}, 'leftover attach race reuses this grant' );
is( $attach_leftover->{role_id},
    'generated-1', 'leftover attach race keeps this role' );
is( $attach_leftover->{permission_id},
    'generated-4', 'leftover attach race keeps this permission' );
is( scalar @{ $attach_leftover_grants->created },
    1, 'leftover attach race does not insert a second grant' );
is( scalar @{ $attach_leftover_audit->created },
    1, 'leftover attach race inserts the missing audit' );

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
is( scalar @{ $audit_log->created },
    $BINDING_AUDIT_ROWS, 'role binding creation is audited' );
is( $audit_log->created->[-1]{action},
    'role_binding.created', 'audit records binding creation' );

my $duplicate_bound = $binding_store->bind_role(
    {
        actor_user_id => 'admin-1',
        user_id       => 'moderator-1',
        role_id       => 'generated-1',
        resource_type => 'space',
        resource_id   => 'space-1',
        space_id      => 'space-1',
    }
);
ok( $duplicate_bound->{idempotent}, 'duplicate role binding is idempotent' );
is( scalar @{ $role_bindings->created },
    $CREATED_BINDINGS, 'duplicate binding avoids duplicate rows' );
is( scalar @{ $audit_log->created },
    $BINDING_AUDIT_ROWS, 'duplicate binding avoids duplicate audit' );

$role_bindings->skip_search(1);
my $raced_bound = $binding_store->bind_role(
    {
        actor_user_id => 'admin-1',
        user_id       => 'moderator-1',
        role_id       => 'generated-1',
        resource_type => 'space',
        resource_id   => 'space-1',
        space_id      => 'space-1',
    }
);
ok( $raced_bound->{idempotent},
    'unique role binding race reuses the active row' );
is( $raced_bound->{binding}{binding_id},
    'generated-1', 'unique role binding race keeps the original binding id' );
is( scalar @{ $role_bindings->created },
    $CREATED_BINDINGS,
    'unique role binding race does not insert a second row' );
is( scalar @{ $audit_log->created },
    $BINDING_AUDIT_ROWS,
    'unique role binding race does not write a second audit' );

my $binding_pk_bindings =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $binding_pk_audit = GPForum::Test::ModerationResultSet->new;
$binding_pk_bindings->create(
    {
        binding_id    => 'generated-1',
        resource_id   => 'other-space',
        resource_type => 'space',
        role_id       => 'other-role',
        space_id      => 'other-space',
        user_id       => 'other-user',
    }
);
my $binding_pk_store = GPForum::Service::Admin::RoleBindingStore->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog    => $binding_pk_audit,
            RoleBinding => $binding_pk_bindings,
        },
    ),
);
my $binding_pk = $binding_pk_store->bind_role(
    {
        actor_user_id => 'admin-1',
        resource_id   => 'space-1',
        resource_type => 'space',
        role_id       => 'generated-1',
        space_id      => 'space-1',
        user_id       => 'moderator-1',
    }
);
ok( $binding_pk->{ok}, 'unique binding id collision remints and binds' );
ok( !$binding_pk->{idempotent},
    'unique binding id collision does not reuse another binding' );
is( $binding_pk->{binding}{binding_id},
    'generated-2', 'unique binding id collision remints the id' );
is( $binding_pk->{binding}{user_id},
    'moderator-1', 'unique binding id collision keeps this user' );

my $binding_leftover_bindings =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $binding_leftover_audit = GPForum::Test::ModerationResultSet->new;
$binding_leftover_bindings->create(
    {
        binding_id    => 'generated-1',
        resource_id   => 'space-1',
        resource_type => 'space',
        role_id       => 'generated-1',
        space_id      => 'space-1',
        user_id       => 'moderator-1',
    }
);
$binding_leftover_bindings->skip_search(1);
my $binding_leftover_store = GPForum::Service::Admin::RoleBindingStore->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog    => $binding_leftover_audit,
            RoleBinding => $binding_leftover_bindings,
        },
    ),
);
my $binding_leftover = $binding_leftover_store->bind_role(
    {
        actor_user_id => 'admin-1',
        resource_id   => 'space-1',
        resource_type => 'space',
        role_id       => 'generated-1',
        space_id      => 'space-1',
        user_id       => 'moderator-1',
    }
);
ok( $binding_leftover->{idempotent},
    'leftover binding id race reuses this binding' );
is( $binding_leftover->{binding}{binding_id},
    'generated-1', 'leftover binding id race keeps this binding' );
is( $binding_leftover->{binding}{user_id},
    'moderator-1', 'leftover binding id race keeps this user' );
is( scalar @{ $binding_leftover_bindings->created },
    1, 'leftover binding id race does not insert a second binding' );
is( scalar @{ $binding_leftover_audit->created },
    1, 'leftover binding id race inserts the missing audit' );

my $revoked = $binding_store->revoke_binding( 'generated-1', 'admin-2' );
is( $revoked->{binding_id}, 'generated-1', 'revoke returns binding id' );
is( $revoked->{revoked_at}, '2026-05-23T12:00:00Z', 'revoke stores timestamp' );
is( $role_bindings->find('generated-1')->get_column('revoked_at'),
    '2026-05-23T12:00:00Z', 'binding row is revoked' );
is( scalar @{ $audit_log->created },
    $REVOKE_AUDIT_ROWS, 'role binding revocation is audited' );
is( $audit_log->created->[-1]{action},
    'role_binding.revoked', 'audit records binding revocation' );
ok( $binding_store->revoke_binding( 'generated-1', 'admin-2' )->{idempotent},
    'duplicate role binding revoke is idempotent' );
is( scalar @{ $audit_log->created },
    $REVOKE_AUDIT_ROWS, 'duplicate revoke avoids duplicate audit' );
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
is( $role_bindings->last_query->{'me.resource_id'},
    undef, 'unscoped permission gate requires a global resource_id' );
is( $role_bindings->last_query->{'me.space_id'},
    undef, 'unscoped permission gate requires a global space_id' );
ok( !exists $role_bindings->last_query->{-or},
    'unscoped permission gate never widens to scoped bindings' );

$permission_gate->allowed(
    { user_id => 'moderator-1' },
    {
        resource_type => 'report',
        action        => 'view_queue',
        resource_id   => 'category-1',
        space_id      => 'space-1',
    },
);
is_deeply(
    $role_bindings->last_query->{-or},
    [
        { 'me.resource_id' => undef,        'me.space_id' => undef },
        { 'me.resource_id' => 'category-1', 'me.space_id' => 'space-1' },
    ],
    'scoped permission gate accepts global or exactly scoped bindings'
);

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

$users->create(
    {
        id                => 'user-1',
        username          => 'admin_user',
        display_name      => 'Admin User',
        email_normalized  => 'admin@example.test',
        status            => 'active',
        trust_level       => 3,
        email_verified_at => '2026-05-23T12:00:00Z',
        created_at        => '2026-05-23T12:00:00Z',
        updated_at        => '2026-05-23T12:00:00Z',
        deleted_at        => undef,
    }
);
$reports->create(
    {
        report_id                  => 'report-1',
        reporter_user_id           => 'user-2',
        target_type                => 'post',
        target_id                  => 'post-1',
        reason                     => 'spam',
        details                    => 'links',
        status                     => 'open',
        assigned_moderator_user_id => undef,
        created_at                 => '2026-05-23T12:00:00Z',
        resolved_at                => undef,
        resolution                 => undef,
    }
);
$outbox->create(
    {
        outbox_id        => 'outbox-1',
        event_id         => 'event-1',
        queue            => 'default',
        job_type         => 'notification.dispatch',
        idempotency_key  => 'notification.dispatch:event-1',
        available_at     => '2026-05-23T12:00:00Z',
        created_at       => '2026-05-23T12:00:00Z',
        locked_at        => undef,
        attempts         => 1,
        status           => 'pending',
        last_error       => undef,
        next_attempt_at  => '2026-05-23T12:00:00Z',
        locked_by        => undef,
        locked_until     => undef,
        attempt_count    => 1,
        last_error_class => undef,
    }
);
$dead_letters->create(
    {
        dead_letter_id  => 'dead-letter-1',
        source_table    => 'outbox_messages',
        source_id       => 'outbox-1',
        error_class     => 'worker_failed',
        error_message   => 'retry limit exceeded',
        retry_count     => 5,
        first_failed_at => '2026-05-23T11:00:00Z',
        last_failed_at  => '2026-05-23T12:00:00Z',
    }
);
my $console = GPForum::Service::Admin::ConsoleReader->new(
    schema           => $schema,
    readiness        => GPForum::Test::AdminRuntimeStatus->new,
    metrics_snapshot => GPForum::Test::AdminRuntimeStatus->new,
);
is( $console->list_users( { limit => 5 } )->[0]{username},
    'admin_user', 'admin console lists users' );
is( $users->last_attrs->{rows}, 5, 'admin user list applies limit' );
is( $console->async_jobs( { limit => 5 } )->{outbox_messages}[0]{outbox_id},
    'outbox-1', 'admin console lists outbox messages' );
is( $console->async_jobs( { limit => 5 } )->{dead_letters}[0]{dead_letter_id},
    'dead-letter-1', 'admin console lists dead letters' );
is(
    $console->dashboard_summary( { limit => 5 } )
      ->{moderation}{reports}[0]{report_id},
    'report-1',
    'admin console dashboard includes moderation queue'
);
is( $console->operations_status->{readiness}{status},
    'ok', 'admin console exposes health status' );
is( $console->operations_status->{benchmark}{status},
    'manual', 'admin console exposes read-only benchmark status' );

done_testing();

1;

package GPForum::Test::AdminRuntimeStatus;

use Mojo::Base -base;

our $VERSION = '0.001';

sub check {
    return {
        status => 'ok',
        checks => [ { name => 'database', status => 'ok' } ],
    };
}

sub collect {
    return {
        db_query_stats => { requests_observed => 1 },
        outbox         => { pending           => 1 },
        runtime        => { mode              => 'test' },
    };
}

1;
