# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Mojo::Transaction::HTTP;
use Mojo::URL;
use Mojolicious;
use Test::More;

use GPForum::Controller::Admin::Base;
use GPForum::Controller::Moderation::Base;
use GPForum::Controller::Privacy::Base;
use GPForum::Service::Admin::PermissionGate;
use GPForum::Test::RecordingPermissionGate;
use GPForum::Test::ScopeBindingResultSet;
use GPForum::Test::ScopeBindingSchema;

our $VERSION = '0.001';

my @live_transactions;

my $moderate = {
    resource_type => 'thread',
    action        => 'moderate',
};

my $global_gate = _gate(
    {
        'me.resource_id' => undef,
        'me.space_id'    => undef,
    }
);
my $category_gate = _gate(
    {
        'me.resource_id' => 'category-1',
        'me.space_id'    => undef,
    }
);
my $space_gate = _gate(
    {
        'me.resource_id' => undef,
        'me.space_id'    => 'space-1',
    }
);
my $pair_gate = _gate(
    {
        'me.resource_id' => 'category-2',
        'me.space_id'    => 'space-2',
    }
);
my $revoked_gate = _gate(
    {
        'me.resource_id' => undef,
        'me.space_id'    => undef,
        'me.revoked_at'  => '2026-05-23T12:00:00Z',
    }
);

ok(
    $global_gate->allowed( { user_id => 'moderator-1' }, $moderate ),
    'global binding satisfies an unscoped permission check'
);
ok(
    $global_gate->allowed(
        { user_id                   => 'moderator-1' },
        { %{$moderate}, resource_id => 'category-1' },
    ),
    'global binding satisfies a scoped permission check'
);
ok( !$revoked_gate->allowed( { user_id => 'moderator-1' }, $moderate ),
    'revoked global binding satisfies nothing' );

ok(
    !$category_gate->allowed( { user_id => 'moderator-1' }, $moderate ),
    'category binding does not satisfy an unscoped permission check'
);
ok(
    $category_gate->allowed(
        { user_id                   => 'moderator-1' },
        { %{$moderate}, resource_id => 'category-1' },
    ),
    'category binding satisfies its own resource scope'
);
ok(
    !$category_gate->allowed(
        { user_id                   => 'moderator-1' },
        { %{$moderate}, resource_id => 'category-9' },
    ),
    'category binding does not satisfy another resource scope'
);
ok(
    !$category_gate->allowed(
        { user_id                   => 'moderator-1' },
        { %{$moderate}, resource_id => 'category-1', space_id => 'space-1' },
    ),
    'category binding does not satisfy a wider resource and space scope'
);
ok(
    !$category_gate->allowed(
        { user_id                   => 'moderator-1' },
        { %{$moderate}, resource_id => q{} },
    ),
    'empty resource scope is treated as unscoped and stays fail-closed'
);

ok(
    $space_gate->allowed(
        { user_id                => 'moderator-1' },
        { %{$moderate}, space_id => 'space-1' },
    ),
    'space binding satisfies its own space scope'
);
ok(
    !$space_gate->allowed( { user_id => 'moderator-1' }, $moderate ),
    'space binding does not satisfy an unscoped permission check'
);

ok(
    $pair_gate->allowed(
        { user_id                   => 'moderator-1' },
        { %{$moderate}, resource_id => 'category-2', space_id => 'space-2' },
    ),
    'resource and space binding satisfies the matching scope'
);
ok(
    !$pair_gate->allowed(
        { user_id                   => 'moderator-1' },
        { %{$moderate}, resource_id => 'category-2' },
    ),
    'resource and space binding rejects a partial scope match'
);

ok(
    !$global_gate->allowed(
        { user_id       => 'moderator-1' },
        { resource_type => 'thread', action => 'reverse' },
    ),
    'global binding still respects the requested action'
);
ok( !$global_gate->allowed( {}, $moderate ), 'anonymous actors are denied' );

my $unscoped_resultset =
  GPForum::Test::ScopeBindingResultSet->new( bindings => [] );
GPForum::Service::Admin::PermissionGate->new(
    schema => GPForum::Test::ScopeBindingSchema->new(
        role_bindings => $unscoped_resultset
    )
)->allowed( { user_id => 'moderator-1' }, $moderate );
my $unscoped_query = $unscoped_resultset->last_query;
ok(
    exists $unscoped_query->{'me.resource_id'},
    'unscoped query constrains resource_id'
);
is( $unscoped_query->{'me.resource_id'},
    undef, 'unscoped query requires a null resource_id' );
is( $unscoped_query->{'me.space_id'},
    undef, 'unscoped query requires a null space_id' );
ok( !exists $unscoped_query->{-or},
    'unscoped query accepts global bindings only' );

my $scoped_resultset =
  GPForum::Test::ScopeBindingResultSet->new( bindings => [] );
GPForum::Service::Admin::PermissionGate->new(
    schema => GPForum::Test::ScopeBindingSchema->new(
        role_bindings => $scoped_resultset
    )
)->allowed( { user_id => 'moderator-1' },
    { %{$moderate}, resource_id => 'category-1' } );
is_deeply(
    $scoped_resultset->last_query->{-or},
    [
        { 'me.resource_id' => undef,        'me.space_id' => undef },
        { 'me.resource_id' => 'category-1', 'me.space_id' => undef },
    ],
    'scoped query accepts global or exactly scoped bindings'
);

my $application = Mojolicious->new;
$application->log->level('fatal');
$application->secrets( ['permission-scope-test-secret'] );
my $gate_recorder = GPForum::Test::RecordingPermissionGate->new;
$application->helper( gp_permission_gate => sub { return $gate_recorder; } );

my $moderation = _controller(
    $application,
    'GPForum::Controller::Moderation::Base',
    '/moderation/threads/thread-1/lock'
);
$moderation->stash( thread_id => 'thread-1' );
is_deeply(
    $moderation->write_permission_scope('thread'),
    { resource_id => 'thread-1', space_id => undef },
    'moderation write scope uses the thread route placeholder'
);
is_deeply(
    $moderation->write_permission_scope('post'),
    { resource_id => undef, space_id => undef },
    'moderation write scope stays global without a matching placeholder'
);
is_deeply(
    $moderation->write_permission_scope('suspension'),
    { resource_id => undef, space_id => undef },
    'moderation suspension revoke has no placeholder scope'
);
is_deeply(
    $moderation->global_permission_scope,
    { resource_id => undef, space_id => undef },
    'moderation global scope names both columns explicitly'
);

my $injected = _controller(
    $application,
    'GPForum::Controller::Moderation::Base',
    '/moderation/reports/report-1/assign?thread_id=thread-9'
);
is_deeply(
    $injected->write_permission_scope('thread'),
    { resource_id => undef, space_id => undef },
    'query parameters cannot widen a moderation write scope'
);

$moderation->session( user_id => 'moderator-1' );
is( $moderation->authorized_user_id('view_queue'),
    'moderator-1', 'moderation reads authorize the session actor' );
is_deeply(
    $gate_recorder->last_permission,
    {
        action        => 'view_queue',
        resource_type => 'report',
        resource_id   => undef,
        space_id      => undef,
    },
    'moderation reads ask the gate for a global binding'
);

my $admin = _controller(
    $application,
    'GPForum::Controller::Admin::Base',
    '/admin/users/user-1/roles?resource_id=category-1&space_id=space-1'
);
$admin->stash( action => 'bind_role' );
is_deeply(
    $admin->write_permission_scope,
    { resource_id => 'category-1', space_id => 'space-1' },
    'admin binding writes scope to the requested resource and space'
);
$admin->stash( action => 'create_role' );
is_deeply(
    $admin->write_permission_scope,
    { resource_id => undef, space_id => undef },
    'other admin writes ignore resource_id and space_id parameters'
);

$admin->session( user_id => 'admin-1' );
is( $admin->authorized_user_id('view'),
    'admin-1', 'admin reads authorize the session actor' );
is_deeply(
    $gate_recorder->last_permission,
    {
        action        => 'view',
        resource_type => 'admin_console',
        resource_id   => undef,
        space_id      => undef,
    },
    'admin reads ask the gate for a global binding'
);

is_deeply(
    GPForum::Controller::Privacy::Base->new->global_permission_scope,
    { resource_id => undef, space_id => undef },
    'privacy checks are global by declaration'
);

done_testing();

sub _gate {
    my ($binding) = @_;

    return GPForum::Service::Admin::PermissionGate->new(
        schema => GPForum::Test::ScopeBindingSchema->new(
            role_bindings => GPForum::Test::ScopeBindingResultSet->new(
                bindings => [ _binding($binding) ],
            ),
        ),
    );
}

sub _binding {
    my ($binding) = @_;

    return {
        'me.user_id'               => 'moderator-1',
        'me.revoked_at'            => undef,
        'permission.resource_type' => 'thread',
        'permission.action'        => 'moderate',
        %{$binding},
    };
}

sub _controller {
    my ( $host, $class, $path ) = @_;

    my $transaction = Mojo::Transaction::HTTP->new;
    $transaction->req->url( Mojo::URL->new($path) );
    push @live_transactions, $transaction;

    return $class->new( app => $host, tx => $transaction );
}

1;
