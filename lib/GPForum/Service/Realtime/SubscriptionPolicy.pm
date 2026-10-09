# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Realtime::SubscriptionPolicy;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

const my $ACTION_SUBSCRIBE => 'realtime.subscribe';
const my $STATUS_ACTIVE    => 'active';

has permission_gate => undef; # optional: without one roles grant nothing
has readability     => undef; # optional: without one threads are invisible
has schema          => undef; # optional: without one account status is not read
has suspension_store => undef;  # optional: without one suspensions are not read

# Named `permits` rather than `can`, which would override UNIVERSAL::can.
# actor, action, resource and context are the authorization question; collapsing
# them into one hashref would hide which of them a caller forgot.
sub permits ( $self, $actor, $action, $resource, $context ) {
    return _deny('forbidden')               if $action ne $ACTION_SUBSCRIBE;
    return _deny('authentication_required') if !_user_id($actor);

    my $account = $self->_actor_account_status($actor);
    return $account if !$account->{ok};

    my $type = $resource->{type} || q{};
    return $self->_can_thread( $actor, $resource ) if $type eq 'thread';
    return $self->_can_privileged_channel( $actor, $resource )
      if $type eq 'admin' || $type eq 'moderation';
    return $self->_can_feed( $actor, $resource ) if $type eq 'feed';

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

# Fails closed. A suspension store that errors or answers nothing is not an
# answer that the member may participate: a failure was ignored, so a
# suspended member could subscribe whenever the store was unreachable.
sub _actor_account_status ( $self, $actor ) {
    my $user_id = _user_id($actor);
    if ( $self->suspension_store ) {
        my $decision;
        try {
            $decision = $self->suspension_store->can_participate($user_id);
        }
        catch ($error) {
            return _deny('forbidden');
        };
        return _deny('forbidden')
          if ref $decision ne 'HASH' || !$decision->{ok};
    }

    return _allow('account_active') if !$self->schema;

    my $user;
    try {
        $user = $self->schema->resultset('User')->find($user_id);
    }
    catch ($error) {
        return _deny('authentication_required');
    };
    return _deny('authentication_required') if !$user;

    my $status = _column( $user, 'status' ) || $STATUS_ACTIVE;
    return _deny('forbidden') if $status ne $STATUS_ACTIVE;

    return _allow('account_active');
}

sub _user_id ($actor) {
    return undef             if !defined $actor;
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

__END__

=head1 NAME

GPForum::Service::Realtime::SubscriptionPolicy - Who may subscribe to a thread, feed, admin or moderation channel.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $policy = GPForum::Service::Realtime::SubscriptionPolicy->new(
        permission_gate  => $permission_gate,
        readability      => $readability,
        schema           => $schema,
        suspension_store => $suspension_store,
    );
    my $decision = $policy->permits( $actor, 'realtime.subscribe',
        { type => 'thread', id => $thread_id }, {} );
    # { ok => 1, reason => 'thread_readable' }

=head1 DESCRIPTION

The rule L<GPForum::Service::Realtime::ChannelAuthorizer> asks before a
socket joins a channel (notification channels it decides itself). The
account comes first: the actor must be signed in, allowed to participate by
the suspension store, and an C<active> user. Then the channel type decides:

=over 4

=item thread

Open to whoever can read the thread -- its space, category and thread, live
and not hidden -- as every other surface judges it (ADR 0102), through
L<GPForum::Service::Forum::Readability>.

=item admin, moderation

Need the C<admin.view> or C<moderation.review> permission from the
permission gate.

=item feed

Only the actor's own feed: the id must be the actor's user id or
C<personal>.

=back

It fails closed. A suspension store that errors or gives no answer denies,
since ignoring that failure once let a suspended member subscribe whenever
the store was unreachable; a missing readability service or permission gate
denies too.

=head1 SUBROUTINES/METHODS

=head2 permits

Takes the actor (a hash reference with C<user_id>, or a bare user id), the
action, the resource (C<< { type => ..., id => ... } >>) and a context that
is not read. Named C<permits> rather than C<can>, which would override
C<UNIVERSAL::can>.

Returns C<< { ok => 1, reason => $reason } >> with C<thread_readable>,
C<permission_allowed> or C<own_feed>, or
C<< { ok => 0, reason => $reason } >> with C<forbidden> (an action other
than C<realtime.subscribe>, a suspended or inactive account, or a refused
permission or feed),
C<authentication_required> (no user id, no such user, or a user lookup that
died),
C<invisible_resource> (a thread the actor cannot read) or C<unknown_channel>.

=head1 DIAGNOSTICS

None. Errors from the suspension store and the user lookup are caught and
deny.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Forum::Readability>,
L<GPForum::Service::Admin::PermissionGate>,
L<GPForum::Service::Moderation::SuspensionStore>, all passed in by
L<GPForum::Bootstrap::Core>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Without a C<suspension_store> suspensions are not checked, and without a
C<schema> the account status is not. Errors from the readability service and
the permission gate are not caught.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
