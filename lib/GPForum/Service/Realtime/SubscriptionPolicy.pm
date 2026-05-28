package GPForum::Service::Realtime::SubscriptionPolicy;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $ACTION_SUBSCRIBE => 'realtime.subscribe';
const my $STATE_VISIBLE    => 'visible';
const my $STATE_LOCKED     => 'locked';
const my $STATUS_ACTIVE    => 'active';

has permission_gate  => undef;
has schema           => undef;
has suspension_store => undef;

sub can {
    my ( $self, $actor, $action, $resource, $context ) = @_;

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

sub _can_thread {
    my ( $self, $actor, $resource ) = @_;

    return _deny('invisible_resource') if !$self->schema;

    my $thread = eval {
        return $self->schema->resultset('Thread')->find(
            $resource->{id},
            {
                columns => [
                    qw(
                      thread_id category_id author_user_id visibility
                      moderation_state deleted_at
                    )
                ],
            },
        );
    };
    return _deny('invisible_resource') if !$thread;

    return _deny('invisible_resource')
      if defined _column( $thread, 'deleted_at' );
    return _deny('invisible_resource')
      if !_visible_moderation_state( _column( $thread, 'moderation_state' ) );

    my $category = $self->_category_for($thread);
    return _deny('invisible_resource') if !$category;
    return _deny('invisible_resource')
      if defined _column( $category, 'deleted_at' );

    return _allow('thread_visible')
      if _public( _column( $thread,   'visibility' ) )
      && _public( _column( $category, 'visibility' ) );

    return _allow('thread_owner')
      if _column( $thread, 'author_user_id' ) eq _user_id($actor);

    return _allow('thread_acl')
      if $self->_has_acl( $actor, 'thread', _column( $thread, 'thread_id' ) );
    return _allow('category_acl')
      if $self->_has_acl( $actor, 'category',
        _column( $thread, 'category_id' ) );

    return _deny('invisible_resource');
}

sub _can_privileged_channel {
    my ( $self, $actor, $resource ) = @_;

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

sub _can_feed {
    my ( $self, $actor, $resource ) = @_;

    return _allow('own_feed')
      if $resource->{id} eq _user_id($actor)
      || $resource->{id} eq 'personal';

    return _deny('forbidden');
}

sub _can_presence {
    my ( $self, $actor, $resource ) = @_;

    return _allow('authenticated_presence') if length $resource->{id};

    return _deny('malformed_channel');
}

sub _actor_account_status {
    my ( $self, $actor ) = @_;

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

sub _category_for {
    my ( $self, $thread ) = @_;

    return eval {
        return $self->schema->resultset('Category')
          ->find( _column( $thread, 'category_id' ) );
    };
}

sub _has_acl {
    my ( $self, $actor, $resource_type, $resource_id ) = @_;

    return 0 if !$self->schema;
    return 0 if !defined $resource_id || !length $resource_id;

    my $search = eval {
        return $self->schema->resultset('ResourceAcl')->search(
            {
                resource_type    => $resource_type,
                resource_id      => $resource_id,
                user_id          => _user_id($actor),
                revoked_at       => undef,
                moderation_state =>
                  { -in => [ $STATE_VISIBLE, $STATE_LOCKED ] },
            },
            { rows => 1 },
        );
    };
    return 0 if !$search;

    return $search->single ? 1 : 0;
}

sub _visible_moderation_state {
    my ($state) = @_;

    return
      defined $state && ( $state eq $STATE_VISIBLE || $state eq $STATE_LOCKED )
      ? 1
      : 0;
}

sub _public {
    my ($visibility) = @_;

    return defined $visibility && $visibility eq 'public' ? 1 : 0;
}

sub _user_id {
    my ($actor) = @_;

    return                   if !defined $actor;
    return $actor->{user_id} if ref $actor eq 'HASH';

    return $actor;
}

sub _column {
    my ( $row, $column ) = @_;

    return $row->get_column($column) if $row->can('get_column');

    return $row->{$column};
}

sub _allow {
    my ($reason) = @_;

    return { ok => 1, reason => $reason };
}

sub _deny {
    my ($reason) = @_;

    return { ok => 0, reason => $reason };
}

1;
