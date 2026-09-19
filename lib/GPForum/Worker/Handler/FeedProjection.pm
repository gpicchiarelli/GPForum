package GPForum::Worker::Handler::FeedProjection;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $THREAD_CREATED => 'thread.created';
const my $POST_CREATED   => 'post.created';
const my $POST_HIDDEN    => 'post.hidden';
const my $POST_RESTORED  => 'post.restored';
const my $THREAD_TARGET  => 'thread';
const my $POST_ITEM      => 'post';

const my %SUPPORTED => (
    $POST_CREATED   => 1,
    $POST_HIDDEN    => 1,
    $POST_RESTORED  => 1,
    $THREAD_CREATED => 1,
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

    return $event->{aggregate_id} if _is_thread_create($event);

    my $thread_id = _event_value( $event, 'thread_id' );
    return $thread_id if _has_text($thread_id);

    return $self->_schema_column( $event, 'thread_id' );
}

sub _schema_column {
    my ( $self, $event, $name ) = @_;

    return if !$self->schema;

    my $row = $self->schema->resultset('Post')->find( $event->{aggregate_id} );
    return if !$row;

    return $row->get_column($name);
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

    return $THREAD_TARGET if _is_thread_create($event);

    return $POST_ITEM;
}

sub _is_hide {
    my ($event) = @_;

    return ( $event->{event_type} || q{} ) eq $POST_HIDDEN ? 1 : 0;
}

sub _is_create {
    my ($event) = @_;

    my $event_type = $event->{event_type} || q{};

    return $event_type eq $THREAD_CREATED || $event_type eq $POST_CREATED
      ? 1
      : 0;
}

sub _is_thread_create {
    my ($event) = @_;

    return ( $event->{event_type} || q{} ) eq $THREAD_CREATED ? 1 : 0;
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

Outbox handler for C<thread.created>, C<post.created>, C<post.hidden>, and
C<post.restored>. Create and restore call
L<GPForum::Service::Community::FeedProjector/project_item> for the author and
active thread subscribers. Hide calls
L<GPForum::Service::Community::FeedProjector/remove_item> so C</feed> drops
moderated posts.

=head1 SUBROUTINES/METHODS

=head2 supports

True for created thread and post events, plus post hide and restore.

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
