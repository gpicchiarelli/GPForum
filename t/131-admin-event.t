# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Service::Admin::Event;
use Test::More;

our $VERSION = '0.001';

const my $SCHEMA_VERSION => 1;

my $events  = GPForum::Service::Admin::Event->new;
my $binding = {
    binding_id    => 'bind-1',
    resource_id   => 'forum-1',
    resource_type => 'forum',
    role_id       => 'role-1',
    space_id      => undef,
    user_id       => 'user-1',
};

my $created = $events->binding_audit(
    {
        action        => 'role_binding.created',
        actor_user_id => 'admin-1',
        binding       => $binding,
        created_at    => '2026-09-19T12:00:00Z',
    }
);
is( $created->{action},
    'role_binding.created', 'binding_audit uses the created action' );
is( $created->{target_type},
    'role_binding', 'binding_audit uses the role_binding target' );
is( $created->{target_id}, 'bind-1', 'binding_audit targets the binding id' );
is( $created->{schema_version},
    $SCHEMA_VERSION, 'binding_audit uses schema version 1' );
is( $created->{metadata}{user_id},
    'user-1', 'binding_audit records the bound user' );
is( $created->{metadata}{role_id},
    'role-1', 'binding_audit records the bound role' );
is( $created->{previous_hash},
    undef, 'binding_audit leaves previous_hash for the recorder' );

my $revoked = $events->binding_audit(
    {
        action        => 'role_binding.revoked',
        actor_user_id => 'admin-2',
        binding       => $binding,
        created_at    => '2026-09-19T12:01:00Z',
    }
);
is( $revoked->{action},
    'role_binding.revoked', 'binding_audit uses the revoked action' );
is( $revoked->{actor_id},
    'admin-2', 'binding_audit records the revoking actor' );

is_deeply(
    $events->catalog_audit(
        {
            action        => 'role.created',
            actor_user_id => 'admin-1',
            created_at    => '2026-09-19T12:02:00Z',
            metadata      => undef,
            target_id     => 'role-1',
            target_type   => 'role',
        }
    ),
    {
        action         => 'role.created',
        actor_id       => 'admin-1',
        created_at     => '2026-09-19T12:02:00Z',
        metadata       => {},
        previous_hash  => undef,
        record_hash    => q{},
        schema_version => $SCHEMA_VERSION,
        target_id      => 'role-1',
        target_type    => 'role',
    },
    'catalog_audit defaults missing metadata to an empty hash'
);

is_deeply(
    $events->catalog_audit(
        {
            action        => 'permission.created',
            actor_user_id => 'admin-1',
            created_at    => '2026-09-19T12:03:00Z',
            metadata      => {
                action        => 'hide',
                name          => 'hide post',
                resource_type => 'post',
            },
            target_id   => 'perm-1',
            target_type => 'permission',
        }
    )->{metadata},
    {
        action        => 'hide',
        name          => 'hide post',
        resource_type => 'post',
    },
    'catalog_audit keeps explicit permission metadata'
);

my $category = {
    category_id => 'category-1',
    position    => 1,
    slug        => 'general',
    space_id    => 'space-1',
    title       => 'General',
    version     => 2,
    visibility  => 'public',
};
my $category_audit = $events->category_audit(
    {
        action         => 'category.created',
        actor_user_id  => 'admin-1',
        category       => $category,
        correlation_id => 'corr-1',
        created_at     => '2026-09-19T12:04:00Z',
    }
);
is( $category_audit->{target_type},
    'category', 'category_audit uses the category target' );
is( $category_audit->{target_id},
    'category-1', 'category_audit targets the category id' );
is( $category_audit->{correlation_id},
    'corr-1', 'category_audit keeps the write correlation' );
is( $category_audit->{metadata}{slug},
    'general', 'category_audit records the category slug' );

my $category_event = $events->category_event(
    {
        action         => 'category.updated',
        actor_user_id  => 'admin-2',
        category       => $category,
        correlation_id => 'corr-2',
    }
);
is( $category_event->{event_type},
    'category.updated', 'category_event uses the write action' );
is( $category_event->{aggregate_type},
    'category', 'category_event uses the category aggregate' );
is( $category_event->{idempotency_key},
    'category.updated:category-1',
    'category_event keys the write by action and id' );
is( $category_event->{payload}{space_id},
    'space-1', 'category_event records the parent space' );

done_testing();

1;
