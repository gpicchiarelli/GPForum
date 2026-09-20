package GPForum::Worker::Handler::FeedProjection;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $THREAD_CREATED   => 'thread.created';
const my $THREAD_DELETED   => 'thread.deleted';
const my $THREAD_HIDDEN    => 'thread.hidden';
const my $THREAD_RESTORED  => 'thread.restored';
const my $THREAD_UNDELETED => 'thread.undeleted';
const my $POST_CREATED     => 'post.created';
const my $POST_UPDATED     => 'post.updated';
const my $POST_DELETED     => 'post.deleted';
const my $POST_HIDDEN      => 'post.hidden';
const my $POST_RESTORED    => 'post.restored';
const my $POST_UNDELETED   => 'post.undeleted';
const my $THREAD_TARGET    => 'thread';
const my $POST_ITEM        => 'post';

const my %SUPPORTED => (
    $POST_CREATED     => 1,
    $POST_DELETED     => 1,
    $POST_HIDDEN      => 1,
    $POST_RESTORED    => 1,
    $POST_UNDELETED   => 1,
    $POST_UPDATED     => 1,
    $THREAD_CREATED   => 1,
    $THREAD_DELETED   => 1,
    $THREAD_HIDDEN    => 1,
    $THREAD_RESTORED  => 1,
    $THREAD_UNDELETED => 1,
);

const my %FEED_HIDE => (
    $POST_DELETED   => 1,
    $POST_HIDDEN    => 1,
    $THREAD_DELETED => 1,
    $THREAD_HIDDEN  => 1,
);

const my %THREAD_ITEM => (
    $THREAD_CREATED   => 1,
    $THREAD_DELETED   => 1,
    $THREAD_HIDDEN    => 1,
    $THREAD_RESTORED  => 1,
    $THREAD_UNDELETED => 1,
);

has clock              => sub { return GPForum::Service::Clock->new; };
has projector          => undef;
has schema             => undef;
has sink               => undef;
has subscription_store => undef;

sub supports {
    my ( undef, $event ) = @_;

    my $event_type = $event->{event_type};
    return 0 if !defined $event_type;
    return exists $SUPPORTED{$event_type} ? 1 : 0;
}

sub handle {
    my ( $self, $event ) = @_;

    my $task = _task($event);
    $self->_capture($task);
    $self->_apply( $event, $task );

    return $task;
}

sub _apply {
    my ( $self, $event, $task ) = @_;

    if ( _is_hide($event) ) {
        $task->{removed} = $self->_remove($task);
        return;
    }

    $task->{projected} = $self->_project( $event, $task );

    return;
}

sub _project {
    my ( $self, $event, $task ) = @_;

    return if !$self->projector;

    return $self->projector->project_item(
        {
            created_at => _created_at( $event, $self->clock ),
            item_id    => $task->{item_id},
            item_type  => $task->{item_type},
            user_ids   => $self->_user_ids($event),
        }
    );
}

sub _remove {
    my ( $self, $task ) = @_;

    return if !$self->projector;
    if ( $task->{item_type} eq $THREAD_TARGET ) {
        return $self->_remove_thread($task);
    }

    return $self->_remove_item($task);
}

sub _remove_thread {
    my ( $self, $task ) = @_;

    my $projector = $self->projector;
    if ( $projector->can('remove_thread') ) {
        return $projector->remove_thread( $task->{item_id} );
    }

    return $self->_remove_item($task);
}

sub _remove_item {
    my ( $self, $task ) = @_;

    return $self->projector->remove_item(
        {
            item_id   => $task->{item_id},
            item_type => $task->{item_type},
        }
    );
}

sub _user_ids {
    my ( $self, $event ) = @_;

    my @users = grep { defined && length }
      ( $self->_author_id($event), $self->_subscriber_ids($event), );

    return [ _unique(@users) ];
}

sub _author_id {
    my ( $self, $event ) = @_;

    my $author = _event_value( $event, 'author_user_id' );
    return $author            if _has_text($author);
    return $event->{actor_id} if _is_create($event);

    return $self->_schema_column( $event, 'author_user_id' );
}

sub _subscriber_ids {
    my ( $self, $event ) = @_;

    return if !$self->subscription_store;

    my $thread_id = $self->_thread_id($event);
    return if !_has_text($thread_id);

    return $self->subscription_store->subscribers_for( $THREAD_TARGET,
        $thread_id );
}

sub _thread_id {
    my ( $self, $event ) = @_;

    if ( _is_thread_item($event) ) {
        return $event->{aggregate_id};
    }

    my $thread_id = _event_value( $event, 'thread_id' );
    return $thread_id if _has_text($thread_id);

    return $self->_schema_column( $event, 'thread_id' );
}

sub _schema_column {
    my ( $self, $event, $name ) = @_;

    if ( !$self->schema ) {
        return;
    }

    my $row = $self->_schema_row($event);
    if ( !$row ) {
        return;
    }

    return $row->get_column($name);
}

sub _schema_row {
    my ( $self, $event ) = @_;

    my $name = _schema_resultset($event);
    if ( !$name ) {
        return;
    }

    return $self->schema->resultset($name)->find( $event->{aggregate_id} );
}

sub _schema_resultset {
    my ($event) = @_;

    if ( _is_thread_item($event) ) {
        return 'Thread';
    }

    return 'Post';
}

sub _capture {
    my ( $self, $task ) = @_;

    return if !$self->sink;

    $self->sink->capture($task);

    return;
}

sub _task {
    my ($event) = @_;

    return {
        action    => _is_hide($event) ? 'feed.remove' : 'feed.project',
        event_id  => $event->{event_id},
        item_id   => $event->{aggregate_id},
        item_type => _item_type($event),
    };
}

sub _item_type {
    my ($event) = @_;

    if ( _is_thread_item($event) ) {
        return $THREAD_TARGET;
    }

    return $POST_ITEM;
}

sub _is_hide {
    my ($event) = @_;

    my $event_type = $event->{event_type};
    if ( !defined $event_type ) {
        return 0;
    }

    return exists $FEED_HIDE{$event_type} ? 1 : 0;
}

sub _is_create {
    my ($event) = @_;

    my $event_type = $event->{event_type} || q{};

    return
         $event_type eq $THREAD_CREATED
      || $event_type eq $POST_CREATED
      || $event_type eq $POST_UPDATED ? 1 : 0;
}

sub _is_thread_item {
    my ($event) = @_;

    my $event_type = $event->{event_type};
    if ( !defined $event_type ) {
        return 0;
    }

    return exists $THREAD_ITEM{$event_type} ? 1 : 0;
}

sub _created_at {
    my ( $event, $clock ) = @_;

    return $event->{timestamp}   if defined $event->{timestamp};
    return $event->{occurred_at} if defined $event->{occurred_at};

    return $clock->now_iso8601;
}

sub _event_value {
    my ( $event, $name ) = @_;

    return $event->{$name} if defined $event->{$name};

    my $payload = $event->{domain_payload} || {};

    return $payload->{$name};
}

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value ? 1 : 0;
}

sub _unique {
    my @values = @_;

    my %seen;

    return grep { !$seen{$_}++ } @values;
}

1;

__END__

=head1 NAME

GPForum::Worker::Handler::FeedProjection - Project created posts and threads.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $handler = GPForum::Worker::Handler::FeedProjection->new(
        projector          => $projector,
        subscription_store => $subscriptions,
    );
    $handler->handle($event) if $handler->supports($event);

=head1 DESCRIPTION

Outbox handler for C<thread.created>, C<thread.deleted>, C<thread.hidden>,
C<thread.restored>, C<thread.undeleted>, C<post.created>,
C<post.updated>, C<post.deleted>, C<post.hidden>, C<post.restored>, and
C<post.undeleted>. Create,
update, restore, and author undelete call
L<GPForum::Service::Community::FeedProjector/project_item> for the author and
active thread subscribers. Hide and author post delete call
L<GPForum::Service::Community::FeedProjector/remove_item>. Author thread
delete and moderation thread hide call
L<GPForum::Service::Community::FeedProjector/remove_thread> so C</feed>
drops the thread item and every post item in that thread.

=head1 SUBROUTINES/METHODS

=head2 supports

True for created thread and post events, plus post hide, restore, author
post delete, author post undelete, author thread delete, author thread
undelete, and moderation thread hide/restore.

=head2 handle

Projects or removes feed items and records a sink task when configured.

=head1 DIAGNOSTICS

Missing recipients produce C<projected = 0>. Missing item keys produce
C<removed = 0>. Projector and subscription lookup errors propagate to the
outbox dispatcher.

=head1 CONFIGURATION AND ENVIRONMENT

Wired from L<GPForum::Bootstrap::Workers> onto the existing outbox transport.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<Mojo::Base>, and L<GPForum::Service::Clock>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

There is no C<thread.hidden> event; locked threads stay readable and keep
their feed rows. Category subscriptions are not consulted.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
