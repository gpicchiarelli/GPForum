package GPForum::Service::Moderation::ActionStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $STATE_VISIBLE  => 'visible';
const my $STATE_HIDDEN   => 'hidden';
const my $STATE_LOCKED   => 'locked';
const my $SCHEMA_VERSION => 1;
const my $TARGET_POST    => 'post';
const my $TARGET_THREAD  => 'thread';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub hide_post {
    my ( $self, $input ) = @_;

    my $timestamp = $self->clock->now_iso8601;
    my $post      = $self->schema->resultset('Post')->find( $input->{post_id} );
    $post->update(
        {
            moderation_state => $STATE_HIDDEN,
            hidden_at        => $timestamp,
        }
    );

    return $self->_record_action(
        {
            actor_user_id => $input->{actor_user_id},
            action_type   => 'post.hidden',
            target_type   => $TARGET_POST,
            target_id     => $input->{post_id},
            reason        => $input->{reason},
            metadata      => { previous_state => $STATE_VISIBLE },
            created_at    => $timestamp,
        }
    );
}

sub restore_post {
    my ( $self, $input ) = @_;

    my $post = $self->schema->resultset('Post')->find( $input->{post_id} );
    $post->update(
        {
            moderation_state => $STATE_VISIBLE,
            hidden_at        => undef,
        }
    );

    return $self->_record_action(
        {
            actor_user_id => $input->{actor_user_id},
            action_type   => 'post.restored',
            target_type   => $TARGET_POST,
            target_id     => $input->{post_id},
            reason        => $input->{reason},
            metadata      => { previous_state => $STATE_HIDDEN },
            created_at    => $self->clock->now_iso8601,
        }
    );
}

sub lock_thread {
    my ( $self, $input ) = @_;

    my $timestamp = $self->clock->now_iso8601;
    my $thread =
      $self->schema->resultset('Thread')->find( $input->{thread_id} );
    $thread->update(
        {
            moderation_state => $STATE_LOCKED,
            locked_at        => $timestamp,
        }
    );

    return $self->_record_action(
        {
            actor_user_id => $input->{actor_user_id},
            action_type   => 'thread.locked',
            target_type   => $TARGET_THREAD,
            target_id     => $input->{thread_id},
            reason        => $input->{reason},
            metadata      => { previous_state => $STATE_VISIBLE },
            created_at    => $timestamp,
        }
    );
}

sub reverse_action {
    my ( $self, $action_id, $reversed_by_user_id ) = @_;

    my $timestamp = $self->clock->now_iso8601;
    my $action = $self->schema->resultset('ModerationAction')->find($action_id);
    my $changes = {
        reversed_at         => $timestamp,
        reversed_by_user_id => $reversed_by_user_id,
    };
    $action->update($changes);

    return { moderation_action_id => $action_id, %{$changes} };
}

sub _record_action {
    my ( $self, $input ) = @_;

    my $action = {
        moderation_action_id => $self->id_service->uuid,
        actor_user_id        => $input->{actor_user_id},
        action_type          => $input->{action_type},
        target_type          => $input->{target_type},
        target_id            => $input->{target_id},
        reason               => $input->{reason},
        metadata             => $input->{metadata} || {},
        created_at           => $input->{created_at},
        reversed_at          => undef,
        reversed_by_user_id  => undef,
    };
    $self->schema->resultset('ModerationAction')->create($action);
    $self->_record_audit($action);

    return { ok => 1, action => $action };
}

sub _record_audit {
    my ( $self, $action ) = @_;

    $self->schema->resultset('AuditLog')->create(
        {
            audit_id       => $self->id_service->uuid,
            action         => $action->{action_type},
            schema_version => $SCHEMA_VERSION,
            actor_id       => $action->{actor_user_id},
            target_type    => $action->{target_type},
            target_id      => $action->{target_id},
            correlation_id => $self->id_service->uuid,
            previous_hash  => undef,
            record_hash    => q{},
            metadata       => {
                reason               => $action->{reason},
                moderation_action_id => $action->{moderation_action_id},
            },
            created_at => $action->{created_at},
        }
    );

    return;
}

1;
