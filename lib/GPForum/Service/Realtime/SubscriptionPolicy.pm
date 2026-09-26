# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Realtime::SubscriptionPolicy;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $ACTION_SUBSCRIBE => 'realtime.subscribe';
const my $STATUS_ACTIVE    => 'active';

has permission_gate  => undef;
has readability      => undef;
has schema           => undef;
has suspension_store => undef;

# Named `permits` rather than `can`, which would override UNIVERSAL::can.
# actor, action, resource and context are the authorization question; collapsing
# them into one hashref would hide which of them a caller forgot.
sub permits ( $self, $actor, $action, $resource, $context ) {    ## no critic (Subroutines::ProhibitManyArgs)
    return _deny('forbidden')               if $action ne $ACTION_SUBSCRIBE;
    return _deny('authentication_required') if !_user_id($actor);

    my $account = $self->_actor_account_status($actor);
    return $account if !$account->{ok};

    my $type = $resource->{type} || q{};
    return $self->_can_thread( $actor, $resource ) if $type eq 'thread';
    return $self->_can_privileged_channel( $actor, $resource )
      if $type eq 'admin' || $type eq 'moderation';
    return $self->_can_feed( $actor, $resource )     if $type eq 'feed';
    return $self->_can_presence( $actor, $resource ) if $type eq 'presence';

    return _deny('unknown_channel');
}

# ADR 0102: a thread channel is open to whoever can read the thread -- its
# space, category and thread, live and not hidden -- as every other surface
# judges it. The old check ignored the space, shut members out of
# members-only threads, and trusted a resource_acl table nothing writes.
sub _can_thread ( $self, $actor, $resource ) {
    return _deny('invisible_resource') if !$self->readability;

    return $self->readability->readable_by( _user_id($actor), 'thread',
        $resource->{id} )
      ? _allow('thread_readable')
      : _deny('invisible_resource');
}

sub _can_privileged_channel ( $self, $actor, $resource ) {
    my %permission_for = (
        admin      => { resource_type => 'admin',      action => 'view' },
        moderation => { resource_type => 'moderation', action => 'review' },
    );
    my $permission = $permission_for{ $resource->{type} };
    return _deny('forbidden') if !$permission;
    return _allow('permission_allowed')
      if $self->permission_gate
      && $self->permission_gate->allowed( $actor, $permission );

    return _deny('forbidden');
}

sub _can_feed ( $self, $actor, $resource ) {
    return _allow('own_feed')
      if $resource->{id} eq _user_id($actor)
      || $resource->{id} eq 'personal';

    return _deny('forbidden');
}

sub _can_presence ( $self, $actor, $resource ) {
    return _allow('authenticated_presence') if length $resource->{id};

    return _deny('malformed_channel');
}

sub _actor_account_status ( $self, $actor ) {
    my $user_id = _user_id($actor);
    if ( $self->suspension_store ) {
        my $decision =
          eval { return $self->suspension_store->can_participate($user_id); };
        return _deny('forbidden') if $decision && !$decision->{ok};
    }

    return _allow('account_active') if !$self->schema;

    my $user =
      eval { return $self->schema->resultset('User')->find($user_id); };
    return _deny('authentication_required') if !$user;

    my $status = _column( $user, 'status' ) || $STATUS_ACTIVE;
    return _deny('forbidden') if $status ne $STATUS_ACTIVE;

    return _allow('account_active');
}

sub _user_id ($actor) {
    my $undefined;
    return $undefined        if !defined $actor;
    return $actor->{user_id} if ref $actor eq 'HASH';

    return $actor;
}

sub _column ( $row, $column ) {
    return $row->get_column($column) if $row->can('get_column');

    return $row->{$column};
}

sub _allow ($reason) {
    return { ok => 1, reason => $reason };
}

sub _deny ($reason) {
    return { ok => 0, reason => $reason };
}

1;
