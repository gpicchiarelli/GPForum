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

my $roles            = GPForum::Test::ModerationResultSet->new;
my $permissions      = GPForum::Test::ModerationResultSet->new;
my $role_permissions = GPForum::Test::ModerationResultSet->new;
my $role_bindings    = GPForum::Test::ModerationResultSet->new;
my $audit_log        = GPForum::Test::ModerationResultSet->new;
my $users            = GPForum::Test::ModerationResultSet->new;
my $reports          = GPForum::Test::ModerationResultSet->new;
my $outbox           = GPForum::Test::ModerationResultSet->new;
my $dead_letters     = GPForum::Test::ModerationResultSet->new;
my $schema           = GPForum::Test::ModerationSchema->new(
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
