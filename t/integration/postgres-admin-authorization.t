# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::Id;
use GPForum::Service::Admin::PermissionGate;
use GPForum::Service::Admin::PermissionReview;
use GPForum::Service::Admin::RoleBindingStore;
use GPForum::Service::Admin::RoleCatalog;
use GPForum::Test::FixedClock;
use GPForum::Test::PgDatabase;
use GPForum::Test::RacedSchema;
use GPForum::Test::ScriptedId;

our $VERSION = '0.001';

const my $NOW          => '2026-05-23T12:00:00Z';
const my $LIST_LIMIT   => 10;
const my $REVIEW_LIMIT => 20;
const my %VIEW_QUEUE   => ( resource_type => 'report', action => 'view_queue' );
const my $UUID => qr{\A [[:xdigit:]]{8} (?: - [[:xdigit:]]{4} ){3}
  - [[:xdigit:]]{12} \z}msx;
const my @TABLES => qw(roles permissions role_permissions role_bindings
  audit_log);

# Sorts before every minted uuid. The member holds this role on a space and
# space_moderator globally, so a review ordered by role alone would list the
# space binding first.
const my $FIRST_ROLE_ID => '00000000-0000-4000-8000-000000000000';

const my $USER_SQL => join q{ },
  'INSERT INTO users (id, username, display_name, email_normalized,',
  q{password_hash, status) VALUES (?, ?, ?, ?, 'x', 'active')};
const my $ROLE_SQL =>
  'INSERT INTO roles (role_id, name, description) VALUES (?, ?, ?)';
const my $PERMISSION_SQL => join q{ },
  'INSERT INTO permissions (permission_id, name, resource_type, action)',
  'VALUES (?, ?, ?, ?)';
const my $GRANT_SQL =>
  'INSERT INTO role_permissions (role_id, permission_id) VALUES (?, ?)';
const my $BINDING_SQL => join q{ },
  'INSERT INTO role_bindings (binding_id, user_id, role_id, resource_type,',
  'resource_id, space_id) VALUES (?, ?, ?, ?, ?, ?)';
const my $ENTRIES_SQL => join q{ },
  'SELECT action, target_type, target_id FROM audit_log',
  'ORDER BY action, target_id';
const my $TARGET_ENTRIES_SQL =>
  'SELECT count(*) FROM audit_log WHERE action = ? AND target_id = ?';
const my $PAIR_ENTRIES_SQL => join q{ },
  'SELECT count(*) FROM audit_log WHERE action = ? AND target_id = ?',
  q{AND metadata->>'permission_id' = ?};
const my $REVOKED_AT_SQL => join q{ },
  q{SELECT to_char(revoked_at AT TIME ZONE 'UTC',},
  q{'YYYY-MM-DD"T"HH24:MI:SS"Z"') FROM role_bindings WHERE binding_id = ?};

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the admin authorization'
      . ' test';
}

# Roles, permissions, their attachment, role bindings at global, space and
# category scope, the review pages and the permission gate, on PostgreSQL.
# These ran on a fake ORM in t/26 whose role_bindings ignored every
# condition: the review listed a revoked binding, and the gate allowed a
# moderator whose only binding was revoked and scoped to a space, because
# any row answered. What t/26 could pin was the shape of the query; here it
# is the rows the query finds. t/integration/postgres-role-admin.t has the
# concurrent cases, with two connections.
my $database = GPForum::Test::PgDatabase->fresh;
my $fixture  = _context($database);

_catalog_writes($fixture);
_catalog_repeats_and_races($fixture);
_catalog_id_collisions($fixture);
_catalog_listing($fixture);
_bindings($fixture);
_binding_id_collisions($fixture);
_revocation($fixture);
_review($fixture);
_gate($fixture);
_partial_scopes($fixture);

done_testing();

sub _context {
    my ($db) = @_;

    my $context = {
        dbh    => $db->dbh,
        ids    => GPForum::Infrastructure::Id->new,
        schema => $db->schema,
    };
    for my $name (qw(admin moderator member revoker warden curator)) {
        my $id = $context->{ids}->uuid;
        $context->{dbh}->do( $USER_SQL, undef, $id, $name, ucfirst $name,
            "$name\@example.test" );
        $context->{users}{$name} = $id;
    }
    $context->{scope} =
      { map { $_ => $context->{ids}->uuid } qw(space category other_category) };

    return $context;
}

sub _catalog_writes {
    my ($ctx) = @_;

    my $role = _catalog_call(
        $ctx,
        'create_role',
        {
            description => 'Scoped moderation authority',
            name        => 'space_moderator',
        }
    );
    like( $role->{role_id}, $UUID, 'role id is generated' );
    is( $role->{name}, 'space_moderator', 'role stores name' );
    is(
        $role->{description},
        'Scoped moderation authority',
        'role stores description'
    );
    is( $role->{created_at}, $NOW, 'role stores creation time' );

    my $permission = _catalog_call(
        $ctx,
        'create_permission',
        {
            action        => 'view_queue',
            name          => 'report.view_queue',
            resource_type => 'report',
        }
    );
    like( $permission->{permission_id}, $UUID, 'permission id is generated' );
    is( $permission->{name}, 'report.view_queue', 'permission stores name' );
    is( $permission->{resource_type},
        'report', 'permission stores resource type' );
    is( $permission->{action}, 'view_queue', 'permission stores action' );

    my $attached = _catalog_call( $ctx, 'attach_permission',
        _pair( $role->{role_id}, $permission->{permission_id} ) );
    is( $attached->{role_id}, $role->{role_id}, 'role permission stores role' );
    is(
        $attached->{permission_id},
        $permission->{permission_id},
        'role permission stores permission'
    );

    is_deeply(
        _tally($ctx),
        {
            audit_log        => 3,
            permissions      => 1,
            role_bindings    => 0,
            role_permissions => 1,
            roles            => 1,
        },
        'one role, one permission and one attachment are stored'
    );
    is_deeply(
        $ctx->{dbh}->selectall_arrayref($ENTRIES_SQL),
        [
            [
                'permission.created', 'permission', $permission->{permission_id}
            ],
            [ 'role.created',             'role', $role->{role_id} ],
            [ 'role_permission.attached', 'role', $role->{role_id} ],
        ],
        'the role catalog audits every mutation'
    );

    $ctx->{role_id}       = $role->{role_id};
    $ctx->{permission_id} = $permission->{permission_id};

    return;
}

# The same write again finds the row. A lookup that misses it, as one made
# just before a concurrent write commits does, meets the unique key and
# reuses the row. Neither adds a row or an audit entry.
sub _catalog_repeats_and_races {
    my ($ctx) = @_;

    my @writes = (
        [
            'role',
            'create_role',
            'roles',
            {
                description => 'concurrent role after lookup miss',
                name        => 'space_moderator',
            },
            { Role => 1 },
        ],
        [
            'permission',
            'create_permission',
            'permissions',
            {
                action        => 'view_queue',
                name          => 'report.view_queue',
                resource_type => 'report',
            },
            { Permission => 1 },
        ],
        [
            'role permission',
            'attach_permission',
            'role_permissions',
            _pair( $ctx->{role_id}, $ctx->{permission_id} ),
            { RolePermission => 1 },
        ],
    );
    my $before = _tally($ctx);
    for my $write (@writes) {
        my ( $label, $method, $table, $input, $misses ) = @{$write};
        my ( $repeat, $looked ) = _tried( $ctx, $table,
            sub { return _catalog_call( $ctx, $method, $input ) } );
        ok( $repeat->{idempotent}, "duplicate $label write is idempotent" );
        is( $looked, 0, 'without trying an INSERT' );

        my ( $raced, $tries ) = _tried(
            $ctx, $table,
            sub {
                return _catalog_call( $ctx, $method, $input,
                    misses => $misses );
            }
        );
        ok( $raced->{idempotent},
            "a unique $label race reuses the stored row" );
        is( $tries, 1, 'after the INSERT PostgreSQL refused' );
    }
    is_deeply( _tally($ctx), $before,
        'repeats and races add no row and no audit entry' );

    return;
}

# A minted id that is already stored. When it belongs to another role or
# permission, the catalog mints a new one and creates; when it belongs to the
# very row being created -- committed by an earlier attempt whose audit entry
# was lost -- the catalog reuses that row and writes the missing entry.
sub _catalog_id_collisions {
    my ($ctx) = @_;

    my $other_role = $FIRST_ROLE_ID;
    $ctx->{dbh}->do( $ROLE_SQL, undef, $other_role, 'other_role', q{} );
    my ( $reminted, $role_tries ) = _tried(
        $ctx, 'roles',
        sub {
            return _catalog_call(
                $ctx,
                'create_role',
                {
                    description => 'Reminted authority',
                    name        => 'reminted_role',
                },
                ids => [$other_role]
            );
        }
    );
    ok( !$reminted->{idempotent},
        'unique role id collision remints and creates' );
    isnt( $reminted->{role_id}, $other_role,
        'unique role id collision remints the id' );
    is( $reminted->{name}, 'reminted_role',
        'unique role id collision keeps this role name' );
    is(
        $reminted->{description},
        'Reminted authority',
        'unique role id collision keeps this role description'
    );
    is( $role_tries, 2, 'on the INSERT after the one PostgreSQL refused' );

    my $leftover_role = $ctx->{ids}->uuid;
    $ctx->{dbh}
      ->do( $ROLE_SQL, undef, $leftover_role, 'leftover_role', 'Leftover' );
    my $role_again = _leftover(
        $ctx, 'roles',
        [
            'create_role',
            { description => 'Leftover', name => 'leftover_role' },
            ids    => [$leftover_role],
            misses => { Role => 1 },
        ]
    );
    ok( $role_again->{idempotent}, 'leftover role id race reuses this role' );
    is( $role_again->{role_id},
        $leftover_role, 'leftover role id race keeps this role' );
    is( $role_again->{name}, 'leftover_role',
        'leftover role id race keeps this role name' );
    is( _entries( $ctx, 'role.created', $leftover_role ),
        1, 'leftover role id race inserts the missing audit' );

    my $other_permission = $ctx->{ids}->uuid;
    $ctx->{dbh}->do( $PERMISSION_SQL, undef, $other_permission,
        'other.permission', 'other', 'other_action' );
    my ( $reminted_permission, $permission_tries ) = _tried(
        $ctx,
        'permissions',
        sub {
            return _catalog_call(
                $ctx,
                'create_permission',
                {
                    action        => 'reassign',
                    name          => 'report.reassign',
                    resource_type => 'report',
                },
                ids => [$other_permission]
            );
        }
    );
    ok( !$reminted_permission->{idempotent},
        'unique permission id collision remints and creates' );
    isnt( $reminted_permission->{permission_id},
        $other_permission, 'unique permission id collision remints the id' );
    is( $reminted_permission->{name},
        'report.reassign',
        'unique permission id collision keeps this permission name' );
    is( $reminted_permission->{resource_type},
        'report', 'unique permission id collision keeps this resource type' );
    is( $permission_tries, 2,
        'on the INSERT after the one PostgreSQL refused' );

    my $leftover_permission = $ctx->{ids}->uuid;
    $ctx->{dbh}->do( $PERMISSION_SQL, undef, $leftover_permission,
        'report.close', 'report', 'close' );
    my $permission_again = _leftover(
        $ctx,
        'permissions',
        [
            'create_permission',
            {
                action        => 'close',
                name          => 'report.close',
                resource_type => 'report',
            },
            ids    => [$leftover_permission],
            misses => { Permission => 1 },
        ]
    );
    ok( $permission_again->{idempotent},
        'leftover permission id race reuses this permission' );
    is( $permission_again->{permission_id},
        $leftover_permission,
        'leftover permission id race keeps this permission' );
    is( $permission_again->{name},
        'report.close',
        'leftover permission id race keeps this permission name' );
    is( _entries( $ctx, 'permission.created', $leftover_permission ),
        1, 'leftover permission id race inserts the missing audit' );

    $ctx->{dbh}->do( $GRANT_SQL, undef, $leftover_role, $leftover_permission );
    my $grant_again = _leftover(
        $ctx,
        'role_permissions',
        [
            'attach_permission',
            _pair( $leftover_role, $leftover_permission ),
            misses => { RolePermission => 1 },
        ]
    );
    ok( $grant_again->{idempotent}, 'leftover attach race reuses this grant' );
    is( $grant_again->{role_id},
        $leftover_role, 'leftover attach race keeps this role' );
    is( $grant_again->{permission_id},
        $leftover_permission, 'leftover attach race keeps this permission' );
    my ($pair_entries) =
      $ctx->{dbh}->selectrow_array( $PAIR_ENTRIES_SQL, undef,
        'role_permission.attached', $leftover_role, $leftover_permission );
    is( $pair_entries, 1, 'leftover attach race inserts the missing audit' );

    $ctx->{other_role}  = $other_role;
    $ctx->{reassign_id} = $reminted_permission->{permission_id};

    return;
}

# A leftover: the row is stored, the lookup misses it and the INSERT meets
# it. The answer reuses the row and the table keeps its count.
sub _leftover {
    my ( $ctx, $table, $call ) = @_;

    my ( $method, $input, %options ) = @{$call};
    my $before = _tally($ctx);
    my ( $answer, $tries ) = _tried( $ctx, $table,
        sub { return _catalog_call( $ctx, $method, $input, %options ) } );
    is( $tries, 1, "a leftover in $table meets the INSERT PostgreSQL refused" );
    is( _tally($ctx)->{$table}, $before->{$table}, "and $table gains no row" );

    return $answer;
}

# Roles by name and permissions by resource type, action and name, each list
# capped at its limit.
sub _catalog_listing {
    my ($ctx) = @_;

    my $catalog = _catalog($ctx);
    is_deeply(
        [
            map { $_->get_column('name') }
              @{ $catalog->list_roles( { limit => $LIST_LIMIT } ) }
        ],
        [qw(leftover_role other_role reminted_role space_moderator)],
        'roles are listed by name'
    );
    is( scalar @{ $catalog->list_roles( { limit => 2 } ) },
        2, 'role listing applies limit' );
    is_deeply(
        [
            map { $_->get_column('name') }
              @{ $catalog->list_permissions( { limit => $LIST_LIMIT } ) }
        ],
        [qw(other.permission report.close report.reassign report.view_queue)],
        'permissions are listed by resource type and action'
    );
    is( scalar @{ $catalog->list_permissions( { limit => 2 } ) },
        2, 'permission listing applies limit' );

    return;
}

sub _bindings {
    my ($ctx) = @_;

    my $space = $ctx->{scope}{space};
    my %grant = (
        resource_id   => $space,
        resource_type => 'space',
        role_id       => $ctx->{role_id},
        space_id      => $space,
        user_id       => $ctx->{users}{moderator},
    );
    my $bound = _bind( $ctx, \%grant );
    ok( $bound->{ok}, 'role binding succeeds' );
    like( $bound->{binding}{binding_id}, $UUID,
        'role binding id is generated' );
    is(
        $bound->{binding}{user_id},
        $ctx->{users}{moderator},
        'binding stores user'
    );
    is( $bound->{binding}{role_id}, $ctx->{role_id}, 'binding stores role' );
    is( $bound->{binding}{resource_type},
        'space', 'binding stores resource type' );
    is( $bound->{binding}{resource_id}, $space, 'binding stores resource id' );
    is(
        $bound->{binding}{created_by_user_id},
        $ctx->{users}{admin},
        'binding stores creator'
    );
    my $binding_id = $bound->{binding}{binding_id};
    is( _tally($ctx)->{role_bindings}, 1, 'role binding row is inserted' );
    is( _entries( $ctx, 'role_binding.created', $binding_id ),
        1, 'role binding creation is audited' );

    my $before = _tally($ctx);
    my ( $duplicate, $looked ) =
      _tried( $ctx, 'role_bindings', sub { return _bind( $ctx, \%grant ) } );
    ok( $duplicate->{idempotent}, 'duplicate role binding is idempotent' );
    is( $looked, 0, 'without trying an INSERT' );

    my ( $raced, $tries ) = _tried( $ctx, 'role_bindings',
        sub { return _bind( $ctx, \%grant, misses => { RoleBinding => 1 } ) } );
    ok( $raced->{idempotent},
        'unique role binding race reuses the active row' );
    is( $raced->{binding}{binding_id},
        $binding_id, 'unique role binding race keeps the original binding id' );
    is( $tries, 1, 'after the INSERT PostgreSQL refused' );
    is_deeply( _tally($ctx), $before,
        'duplicates and races add no binding and no audit entry' );

    $ctx->{space_binding} = $binding_id;
    $ctx->{space_grant}   = \%grant;

    return;
}

# The binding id collision grants the moderator the role on one category; the
# leftover gives the member a global grant.
sub _binding_id_collisions {
    my ($ctx) = @_;

    my $taken = $ctx->{ids}->uuid;
    my $space = $ctx->{scope}{space};
    $ctx->{dbh}->do( $BINDING_SQL, undef, $taken, $ctx->{users}{member},
        $ctx->{other_role}, 'space', $space, $space );
    my ( $category, $tries ) = _tried(
        $ctx,
        'role_bindings',
        sub {
            return _bind(
                $ctx,
                {
                    resource_id   => $ctx->{scope}{category},
                    resource_type => 'category',
                    role_id       => $ctx->{role_id},
                    space_id      => $space,
                    user_id       => $ctx->{users}{moderator},
                },
                ids => [$taken]
            );
        }
    );
    ok( $category->{ok}, 'unique binding id collision remints and binds' );
    ok( !$category->{idempotent},
        'unique binding id collision does not reuse another binding' );
    isnt( $category->{binding}{binding_id},
        $taken, 'unique binding id collision remints the id' );
    is(
        $category->{binding}{user_id},
        $ctx->{users}{moderator},
        'unique binding id collision keeps this user'
    );
    is( $tries, 2, 'on the INSERT after the one PostgreSQL refused' );

    my $leftover = $ctx->{ids}->uuid;
    $ctx->{dbh}->do( $BINDING_SQL, undef, $leftover, $ctx->{users}{member},
        $ctx->{role_id}, 'global', undef, undef );
    my $before = _tally($ctx);
    my ( $again, $leftover_tries ) = _tried(
        $ctx,
        'role_bindings',
        sub {
            return _bind(
                $ctx,
                {
                    resource_id   => undef,
                    resource_type => 'global',
                    role_id       => $ctx->{role_id},
                    space_id      => undef,
                    user_id       => $ctx->{users}{member},
                },
                ids    => [$leftover],
                misses => { RoleBinding => 1 }
            );
        }
    );
    ok( $again->{idempotent}, 'leftover binding id race reuses this binding' );
    is( $again->{binding}{binding_id},
        $leftover, 'leftover binding id race keeps this binding' );
    is(
        $again->{binding}{user_id},
        $ctx->{users}{member},
        'leftover binding id race keeps this user'
    );
    is( $leftover_tries, 1, 'after the INSERT PostgreSQL refused' );
    is(
        _tally($ctx)->{role_bindings},
        $before->{role_bindings},
        'leftover binding id race does not insert a second binding'
    );
    is( _entries( $ctx, 'role_binding.created', $leftover ),
        1, 'leftover binding id race inserts the missing audit' );

    $ctx->{category_binding} = $category->{binding}{binding_id};
    $ctx->{global_binding}   = $leftover;
    $ctx->{other_binding}    = $taken;

    return;
}

sub _revocation {
    my ($ctx) = @_;

    my $store = _binding_store($ctx);
    my $revoked =
      $store->revoke_binding( $ctx->{space_binding}, $ctx->{users}{revoker} );
    is( $revoked->{binding_id},
        $ctx->{space_binding}, 'revoke returns binding id' );
    is( $revoked->{revoked_at}, $NOW, 'revoke stores timestamp' );
    is(
        scalar $ctx->{dbh}
          ->selectrow_array( $REVOKED_AT_SQL, undef, $ctx->{space_binding} ),
        $NOW,
        'binding row is revoked'
    );
    is( _entries( $ctx, 'role_binding.revoked', $ctx->{space_binding} ),
        1, 'role binding revocation is audited' );

    ok(
        $store->revoke_binding( $ctx->{space_binding}, $ctx->{users}{revoker} )
          ->{idempotent},
        'duplicate role binding revoke is idempotent'
    );
    is( _entries( $ctx, 'role_binding.revoked', $ctx->{space_binding} ),
        1, 'duplicate revoke avoids duplicate audit' );
    is( $store->revoke_binding( $ctx->{ids}->uuid, $ctx->{users}{revoker} ),
        undef, 'missing role binding cannot be revoked' );

    return;
}

# A member's active bindings by resource type, then role; a role's
# permissions by id. Revoked bindings and other members' or roles' rows are
# not listed.
sub _review {
    my ($ctx) = @_;

    my $review =
      GPForum::Service::Admin::PermissionReview->new(
        schema => $ctx->{schema} );
    is_deeply(
        _binding_ids(
            $review->roles_for_user(
                $ctx->{users}{moderator},
                { limit => $REVIEW_LIMIT }
            )
        ),
        [ $ctx->{category_binding} ],
        q{the moderator's roles leave out the revoked space binding}
    );
    is_deeply(
        _binding_ids(
            $review->roles_for_user(
                $ctx->{users}{member},
                { limit => $REVIEW_LIMIT }
            )
        ),
        [ $ctx->{global_binding}, $ctx->{other_binding} ],
        q{the member's roles are the member's, global before space}
    );
    is_deeply(
        _binding_ids(
            $review->roles_for_user( $ctx->{users}{member}, { limit => 1 } )
        ),
        [ $ctx->{global_binding} ],
        'role review applies limit'
    );

    _catalog_call( $ctx, 'attach_permission',
        _pair( $ctx->{role_id}, $ctx->{reassign_id} ) );
    my @expected = sort { $a cmp $b } $ctx->{permission_id},
      $ctx->{reassign_id};
    is_deeply(
        [
            map { $_->get_column('permission_id') } @{
                $review->permissions_for_role( $ctx->{role_id},
                    { limit => $REVIEW_LIMIT } )
            }
        ],
        \@expected,
        q{the role's permissions are listed by id, and only that role's}
    );
    is(
        scalar
          @{ $review->permissions_for_role( $ctx->{role_id}, { limit => 1 } ) },
        1,
        'permission review applies limit'
    );

    return;
}

# The gate fails closed: a check with no scope wants a global binding, and a
# scope is met by a global binding or by one naming exactly that resource and
# space. The member holds the role globally; the moderator on one category,
# and on the space only through a binding that is revoked, then granted
# again.
sub _gate {
    my ($ctx) = @_;

    my $gate =
      GPForum::Service::Admin::PermissionGate->new( schema => $ctx->{schema} );
    my %scope    = %{ $ctx->{scope} };
    my $unscoped = {%VIEW_QUEUE};
    my $category = {
        %VIEW_QUEUE,
        resource_id => $scope{category},
        space_id    => $scope{space},
    };
    my $space = {
        %VIEW_QUEUE,
        resource_id => $scope{space},
        space_id    => $scope{space},
    };
    my $member    = { user_id => $ctx->{users}{member} };
    my $moderator = { user_id => $ctx->{users}{moderator} };

    ok( $gate->allowed( $member, $unscoped ),
        'permission gate allows a matching global role binding' );
    ok( $gate->allowed( $member, $category ),
        'scoped permission gate accepts a global binding' );
    ok( !$gate->allowed( $moderator, $unscoped ),
        'unscoped permission gate never widens to scoped bindings' );
    ok( $gate->allowed( $moderator, $category ),
        'scoped permission gate accepts an exactly scoped binding' );
    ok(
        !$gate->allowed(
            $moderator, { %{$category}, resource_id => $scope{other_category} }
        ),
        'a binding on one category does not reach another'
    );
    ok( !$gate->allowed( $moderator, { %{$category}, space_id => undef } ),
        'a partial scope match does not count' );
    ok(
        !$gate->allowed( $moderator, $space ),
        'a revoked binding grants nothing'
    );
    ok( !$gate->allowed( $member, { %VIEW_QUEUE, action => 'resolve' } ),
        'permission gate filters action' );
    ok(
        !$gate->allowed( $member, { %VIEW_QUEUE, resource_type => 'thread' } ),
        'permission gate filters resource type'
    );
    ok( !$gate->allowed( { user_id => $ctx->{ids}->uuid }, $unscoped ),
        'permission gate denies without role binding' );
    ok(
        !$gate->allowed( { user_id => q{} }, $unscoped ),
        'permission gate denies without a user'
    );

    my $granted = _bind( $ctx, $ctx->{space_grant} );
    ok( !$granted->{idempotent},
        'a revoked scope can be granted again, as a new binding' );
    isnt( $granted->{binding}{binding_id},
        $ctx->{space_binding}, 'with an id of its own' );
    ok(
        $gate->allowed( $moderator, $space ),
        'the new space binding grants on the space'
    );
    ok(
        !$gate->allowed(
            $moderator, { %{$category}, resource_id => $scope{other_category} }
        ),
        'but not on a category of that space'
    );

    return;
}

# A binding is global only when its resource_id and its space_id are both
# NULL; one naming either is scoped, and meets only a check naming the same
# resource and space. The warden holds the role on a space named by its
# space_id alone, the curator on a category named without its space. An
# empty scope is no scope.
sub _partial_scopes {
    my ($ctx) = @_;

    my %scope = %{ $ctx->{scope} };
    for my $grant (
        [ 'warden',  'space',    undef,            $scope{space} ],
        [ 'curator', 'category', $scope{category}, undef ],
      )
    {
        my ( $name, $type, $resource_id, $space_id ) = @{$grant};
        _bind(
            $ctx,
            {
                resource_id   => $resource_id,
                resource_type => $type,
                role_id       => $ctx->{role_id},
                space_id      => $space_id,
                user_id       => $ctx->{users}{$name},
            }
        );
    }
    my $gate =
      GPForum::Service::Admin::PermissionGate->new( schema => $ctx->{schema} );
    my $warden  = { user_id => $ctx->{users}{warden} };
    my $curator = { user_id => $ctx->{users}{curator} };

    is( _allowed( $gate, $warden, {%VIEW_QUEUE} ),
        0, 'a binding naming only a space is not a global one' );
    is( _allowed( $gate, $curator, {%VIEW_QUEUE} ),
        0, 'nor is one naming only a resource' );
    is(
        _allowed( $gate, $warden, { %VIEW_QUEUE, space_id => $scope{space} } ),
        1,
        'a check naming only a space is met by a binding on that space'
    );
    is(
        _allowed(
            $gate, $warden,
            {
                %VIEW_QUEUE,
                resource_id => $scope{category},
                space_id    => $scope{space},
            }
        ),
        0,
        'but not a check on a category in it'
    );
    is(
        _allowed(
            $gate, $curator,
            { %VIEW_QUEUE, resource_id => $scope{category} }
        ),
        1,
        'a check naming only a resource is met by a binding on that resource'
    );

    my $empty = { %VIEW_QUEUE, resource_id => q{}, space_id => q{} };
    is( _allowed( $gate, { user_id => $ctx->{users}{member} }, $empty ),
        1, 'an empty scope is no scope: a global binding meets it' );
    is( _allowed( $gate, $warden, $empty ), 0, 'and a scoped one does not' );

    return;
}

# The gate's answer, or "died": a scope PostgreSQL cannot read as a uuid
# fails the statement rather than the check.
sub _allowed {
    my ( $gate, $actor, $permission ) = @_;

    my $answer = eval { return $gate->allowed( $actor, $permission ) };

    return $answer // 'died';
}

sub _catalog_call {
    my ( $ctx, $method, $input, %options ) = @_;

    my $catalog = _catalog( $ctx, %options );

    return $ctx->{schema}->txn_do(
        sub {
            return $catalog->$method(
                { actor_user_id => $ctx->{users}{admin}, %{$input} } );
        }
    );
}

sub _catalog {
    my ( $ctx, %options ) = @_;

    return GPForum::Service::Admin::RoleCatalog->new(
        _parts( $ctx, %options ) );
}

sub _bind {
    my ( $ctx, $grant, %options ) = @_;

    return _binding_store( $ctx, %options )
      ->bind_role( { actor_user_id => $ctx->{users}{admin}, %{$grant} } );
}

sub _binding_store {
    my ( $ctx, %options ) = @_;

    return GPForum::Service::Admin::RoleBindingStore->new(
        _parts( $ctx, %options ) );
}

sub _parts {
    my ( $ctx, %options ) = @_;

    my $schema =
      $options{misses}
      ? GPForum::Test::RacedSchema->new(
        misses => $options{misses},
        schema => $ctx->{schema},
      )
      : $ctx->{schema};

    return (
        clock      => GPForum::Test::FixedClock->new( iso8601 => $NOW ),
        id_service =>
          GPForum::Test::ScriptedId->new( next_ids => $options{ids} // [] ),
        schema => $schema,
    );
}

sub _pair {
    my ( $role_id, $permission_id ) = @_;

    return {
        permission_id => $permission_id,
        role_id       => $role_id,
    };
}

sub _binding_ids {
    my ($bindings) = @_;

    return [ map { $_->get_column('binding_id') } @{$bindings} ];
}

sub _entries {
    my ( $ctx, $action, $target_id ) = @_;

    return
      scalar $ctx->{dbh}
      ->selectrow_array( $TARGET_ENTRIES_SQL, undef, $action, $target_id );
}

# What $code returns, and the INSERT statements into $table it sends, as
# DBIx::Class traces them. A race the store lost shows as an INSERT
# PostgreSQL refused, which leaves no row to count.
sub _tried {
    my ( $ctx, $table, $code ) = @_;

    my $storage = $ctx->{schema}->storage;
    my $inserts = 0;
    $storage->debugcb(
        sub {
            my ( undef, $statement ) = @_;
            if ( $statement =~ /\A INSERT [ ] INTO [ ] "?\Q$table\E"? [ ]/msx )
            {
                $inserts++;
            }
            return;
        }
    );
    $storage->debug(1);
    my $result = $code->();
    $storage->debug(0);
    $storage->debugcb(undef);

    return ( $result, $inserts );
}

sub _tally {
    my ($ctx) = @_;

    return {
        map {
            $_ => scalar $ctx->{dbh}->selectrow_array("SELECT count(*) FROM $_")
        } @TABLES
    };
}

1;
