# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::Event;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Infrastructure::Row;
use GPForum::X::Argument;

our $VERSION = '0.001';

const my $SCHEMA_VERSION => 1;

# What each event says, by aggregate: the field of the command's part (its
# post or its thread) that names the actor, the fields of the payload, and
# the fields of the audit row's metadata.
const my %EVENT => (
    post => {
        'post.created' => {
            actor    => 'author_user_id',
            metadata => [qw(thread_id)],
            payload  => [qw(author_user_id post_id revision_id thread_id)],
        },
        'post.updated' => {
            actor    => 'editor_user_id',
            metadata => [qw(revision_id thread_id)],
            payload  => [qw(editor_user_id post_id revision_id thread_id)],
        },
        'post.deleted' => {
            actor    => 'deleted_by',
            metadata => [qw(thread_id)],
            payload  => [qw(deleted_by post_id thread_id)],
        },
        'post.undeleted' => {
            actor    => 'restored_by',
            metadata => [qw(thread_id)],
            payload  => [qw(author_user_id post_id restored_by thread_id)],
        },
    },
    thread => {
        'thread.created' => {
            actor    => 'author_user_id',
            metadata => [qw(title)],
            payload  =>
              [qw(author_user_id category_id thread_id title visibility)],
        },
        'thread.updated' => {
            actor    => 'editor_user_id',
            metadata => [qw(slug title)],
            payload  => [qw(editor_user_id slug thread_id title)],
        },
        'thread.moved' => {
            actor    => 'editor_user_id',
            metadata => [qw(category_id previous_category_id)],
            payload  =>
              [qw(category_id editor_user_id previous_category_id thread_id)],
        },
        'thread.deleted' => {
            actor    => 'deleted_by',
            metadata => [qw(category_id)],
            payload  => [qw(category_id deleted_by thread_id)],
        },
        'thread.undeleted' => {
            actor    => 'restored_by',
            metadata => [qw(category_id)],
            payload  => [qw(author_user_id category_id restored_by thread_id)],
        },
    },
);

# Fields the stored row answers before the command does: a delete or a
# restore command names the thread, the category and the author as the
# workflow read them, the row as the write left it. A title edit's slug and
# title, and a move's category, are the row's as written.
const my %FROM_ROW => (
    post   => { author_user_id => 1, thread_id   => 1 },
    thread => { author_user_id => 1, category_id => 1, slug => 1, title => 1 },
);

sub post_envelope ( $self, $event_type, $input ) {
    return $self->_envelope( 'post', $event_type, $input );
}

sub post_audit ( $self, $event_type, $input ) {
    return _audit( 'post', $event_type, $input );
}

sub thread_envelope ( $self, $event_type, $input ) {
    return $self->_envelope( 'thread', $event_type, $input );
}

sub thread_audit ( $self, $event_type, $input ) {
    return _audit( 'thread', $event_type, $input );
}

# One event per command and event type, so a command replayed after a lost
# response records nothing twice; without a command key, one per aggregate.
sub idempotency_key ( $, $command, $event_type, $aggregate_id ) {
    my $key = $command->{idempotency_key};
    if ( defined $key && length $key ) {
        return join q{:}, 'command', $key, $event_type;
    }

    return join q{:}, $event_type, $aggregate_id;
}

sub _envelope ( $self, $aggregate, $event_type, $input ) {
    my $event = _event( $aggregate, $event_type );
    my $part  = $input->{command}{$aggregate};
    my $id    = $part->{"${aggregate}_id"};

    return {
        actor_id          => $part->{ $event->{actor} },
        aggregate_id      => $id,
        aggregate_type    => $aggregate,
        aggregate_version => $SCHEMA_VERSION,
        causation_id      => $input->{causation_id},
        correlation_id    => $input->{correlation_id},
        event_type        => $event_type,
        idempotency_key   =>
          $self->idempotency_key( $input->{command}, $event_type, $id ),
        payload => _fields( $aggregate, $event->{payload}, $input ),
    };
}

sub _audit ( $aggregate, $event_type, $input ) {
    my $event = _event( $aggregate, $event_type );
    my $part  = $input->{command}{$aggregate};

    return {
        action         => $event_type,
        actor_id       => $part->{ $event->{actor} },
        correlation_id => $input->{correlation_id},
        metadata       => _fields( $aggregate, $event->{metadata}, $input ),
        schema_version => $SCHEMA_VERSION,
        target_id      => $part->{"${aggregate}_id"},
        target_type    => $aggregate,
    };
}

sub _event ( $aggregate, $event_type ) {
    if ( !exists $EVENT{$aggregate}{$event_type} ) {
        GPForum::X::Argument->throw(
            message => "unknown $aggregate event type: $event_type" );
    }

    return $EVENT{$aggregate}{$event_type};
}

sub _fields ( $aggregate, $names, $input ) {
    return { map { $_ => _field( $aggregate, $_, $input ) } @{$names} };
}

sub _field ( $aggregate, $name, $input ) {
    my $command = $input->{command};
    if ( $name eq 'revision_id' ) {
        return $command->{revision}{revision_id};
    }
    if ( !exists $FROM_ROW{$aggregate}{$name} ) {
        return $command->{$aggregate}{$name};
    }

    return GPForum::Infrastructure::Row->column( $input->{$aggregate}, $name )
      || $command->{$aggregate}{$name};
}

1;

__END__

=head1 NAME

GPForum::Service::Forum::Event - The domain events and audit rows of a post's and a thread's writes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $events = GPForum::Service::Forum::Event->new;

    $recorder->record_event(
        %{
            $events->post_envelope(
                'post.deleted',
                {
                    command        => $command,
                    correlation_id => $correlation_id,
                    post           => $post,
                }
            )
        }
    );
    $recorder->record_audit(
        %{ $events->post_audit( 'post.deleted', { ... } ) } );

    $recorder->record_event(
        %{
            $events->thread_envelope( 'thread.moved',
                { command => $command, correlation_id => $id, thread => $row } )
        }
    );

=head1 DESCRIPTION

Builds what L<GPForum::Service::Forum::PostStore> and
L<GPForum::Service::Forum::ThreadStore> hand to
L<GPForum::Infrastructure::EventRecorder>: the event envelope and the audit
row of each write, sharing one correlation id. The aggregate is the post or
the thread, at schema version 1. An event has no causation unless the input
names one: a new thread's opening C<post.created> is caused by its
C<thread.created>.

A post's events are a reply (C<post.created>), an edit (C<post.updated>), a
delete (C<post.deleted>) and a restore (C<post.undeleted>). The actor is the
command's post's C<author_user_id>, C<editor_user_id>, C<deleted_by> or
C<restored_by>. The payloads:

=over 4

=item * C<post.created>: C<author_user_id>, C<post_id>, C<revision_id>,
C<thread_id>; audit metadata C<thread_id>.

=item * C<post.updated>: C<editor_user_id>, C<post_id>, C<revision_id>,
C<thread_id>; audit metadata C<revision_id> and C<thread_id>.

=item * C<post.deleted>: C<deleted_by>, C<post_id>, C<thread_id>; audit
metadata C<thread_id>.

=item * C<post.undeleted>: C<author_user_id>, C<post_id>, C<restored_by>,
C<thread_id>; audit metadata C<thread_id>.

=back

C<revision_id> is the command's revision's. C<thread_id> and
C<author_user_id> are the stored post's when a C<post> row is given, else
the command's post's; every other field is the command's post's.

A thread's events are a new thread (C<thread.created>), a title edit
(C<thread.updated>), a move (C<thread.moved>), a delete (C<thread.deleted>)
and a restore (C<thread.undeleted>). The actor is the command's thread's
C<author_user_id>, C<editor_user_id>, C<deleted_by> or C<restored_by>. The
payloads:

=over 4

=item * C<thread.created>: C<author_user_id>, C<category_id>, C<thread_id>,
C<title>, C<visibility>; audit metadata C<title>.

=item * C<thread.updated>: C<editor_user_id>, C<slug>, C<thread_id>,
C<title>; audit metadata C<slug> and C<title>.

=item * C<thread.moved>: C<category_id>, C<editor_user_id>,
C<previous_category_id>, C<thread_id>; audit metadata C<category_id> and
C<previous_category_id>.

=item * C<thread.deleted>: C<category_id>, C<deleted_by>, C<thread_id>;
audit metadata C<category_id>.

=item * C<thread.undeleted>: C<author_user_id>, C<category_id>,
C<restored_by>, C<thread_id>; audit metadata C<category_id>.

=back

C<author_user_id>, C<category_id>, C<slug> and C<title> are the stored
thread's when a C<thread> row is given, else the command's thread's; every
other field is the command's thread's.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor; it has no attributes.

=head2 post_envelope

Takes an event type and C<< { command, correlation_id, post, causation_id } >>
(C<post> and C<causation_id> optional) and returns the envelope as a hash
reference: the C<event_type>, the C<aggregate_type> C<post>, the
C<aggregate_id> (the command's post id), C<aggregate_version> 1, the
C<actor_id>, the C<correlation_id>, the C<causation_id> (undefined unless
given), the C<idempotency_key> (L</idempotency_key>) and the C<payload>.

=head2 post_audit

Takes the same arguments and returns the audit row: C<action> (the event
type), C<schema_version> 1, C<actor_id>, C<target_type> C<post>,
C<target_id>, C<correlation_id> and C<metadata>.

=head2 thread_envelope

As L</post_envelope>, for a thread's event: the input's optional row is
C<thread>, the C<aggregate_type> is C<thread> and the C<aggregate_id> the
command's thread id.

=head2 thread_audit

As L</post_audit>, for a thread's event: C<target_type> C<thread>.

=head2 idempotency_key

Takes a command, an event type and an aggregate id. Returns
C<command:IDEMPOTENCY_KEY:EVENT_TYPE> when the command carries a non-empty
C<idempotency_key>, else C<EVENT_TYPE:AGGREGATE_ID>.

=head1 DIAGNOSTICS

An event type other than the ones above throws L<GPForum::X::Argument>
(C<unknown post event type: TYPE> or C<unknown thread event type: TYPE>).

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>, L<Const::Fast>, L<GPForum::Infrastructure::Row>,
L<GPForum::X::Argument>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A field the row answers falls back to the command's when the row's value is
false, not only when it is missing.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
