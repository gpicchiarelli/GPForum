# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::ThreadStore;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Domain::Thread;
use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::Storage;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Forum::Event;
use GPForum::X::Conflict;

our $VERSION = '0.001';

const my $COUNTER_ID_CONSTRAINT => 'thread_counters_pkey';

# The rows a new thread inserts by id, each with its result source, its
# primary key constraint, and the parts of a command that carry its id. The
# post is pointed at its body and revision from the command as written.
const my %PART => (
    body => {
        constraint => 'post_bodies_pkey',
        holders    => [qw(body revision)],
        source     => 'PostBody',
    },
    post => {
        constraint => 'posts_pkey',
        holders    => [qw(body post revision)],
        source     => 'Post',
    },
    revision => {
        constraint => 'post_revisions_pkey',
        holders    => [qw(revision)],
        source     => 'PostRevision',
    },
    thread => {
        constraint => 'threads_pkey',
        holders    => [qw(counter post thread)],
        source     => 'Thread',
    },
);

const my $THREAD_LOCK_SQL => join q{ },
  'SELECT author_user_id, deleted_at, locked_at, moderation_state',
  'FROM threads WHERE thread_id = ? FOR UPDATE';

# An author's write of a thread: who the command names as the writer, and the
# rule (GPForum::Domain::Thread) the thread is checked against.
const my %WRITE => (
    'thread.deleted' => {
        rule   => 'edit_refusal',
        writer => 'deleted_by',
    },
    'thread.moved' => {
        rule   => 'edit_refusal',
        writer => 'editor_user_id',
    },
    'thread.undeleted' => {
        rule   => 'restore_refusal',
        writer => 'restored_by',
    },
    'thread.updated' => {
        rule   => 'edit_refusal',
        writer => 'editor_user_id',
    },
);

__PACKAGE__->requires('schema');

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};
has events   => sub { return GPForum::Service::Forum::Event->new; };
has recorder => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};

sub create_thread ( $self, $command ) {
    my $result = $self->schema->txn_do(
        sub {
            return $self->_insert_thread($command);
        }
    );

    return {
        ok      => 1,
        post    => $result->{post},
        skipped => $result->{skipped},
        thread  => $result->{thread},
    };
}

sub edit_thread ( $self, $command ) {
    return $self->_write( 'thread.updated', $command );
}

sub delete_thread ( $self, $command ) {
    return $self->_write( 'thread.deleted', $command );
}

sub restore_thread ( $self, $command ) {
    return $self->_write( 'thread.undeleted', $command );
}

sub move_thread ( $self, $command ) {
    return $self->_write( 'thread.moved', $command );
}

# A thread id already taken by a thread of the same category and slug is an
# earlier run of the same command: its opening post is found, or written
# now, and nothing is recorded. One taken by another thread gives its id up
# for a new one, once. Events are recorded only when this call inserted the
# thread row and wrote its opening post.
sub _insert_thread ( $self, $command ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_thread($command); } );
    return $self->_finish_new_thread($created) if $created;
    if ( !_conflict($error)->on( $PART{thread}{constraint} ) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    my $thread = $self->_find_thread( $command->{thread}{thread_id} );
    if ( !_same_thread( $thread, $command ) ) {
        my $retry = $self->_with_new_id( $command, 'thread' );
        return $self->_finish_new_thread(
            $self->_once_more( sub { return $self->_create_thread($retry); } )
        );
    }

    my $post = $self->_find_post( $command->{post}{post_id} );
    if ( _belongs( $post, thread_id => $command->{post}{thread_id} ) ) {
        return _leftover( $command, $post, $thread );
    }

    return $self->_insert_opening( $command, $thread );
}

sub _create_thread ( $self, $command ) {
    my $thread =
      $self->schema->resultset('Thread')->create( $command->{thread} );

    return $self->_insert_opening( $command, $thread );
}

# The opening post. A post id already taken by a post of the same thread is
# an earlier run's: kept, with its body and revision finished if they are
# not there yet. One taken by another thread's post gives its id up for a
# new one, once. Any other conflict is rethrown.
sub _insert_opening ( $self, $command, $thread ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_opening( $command, $thread ); } );
    return $created if $created;
    if ( !_conflict($error)->on( $PART{post}{constraint} ) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    my $post = $self->_find_post( $command->{post}{post_id} );
    if ( !_belongs( $post, thread_id => $command->{post}{thread_id} ) ) {
        my $retry = $self->_with_new_id( $command, 'post' );
        return $self->_once_more(
            sub { return $self->_create_opening( $retry, $thread ); } );
    }

    my $body = $self->schema->resultset('PostBody')
      ->find( { body_id => $command->{body}{body_id} } );
    if ( _belongs( $body, post_id => $command->{body}{post_id} ) ) {
        return _leftover( $command, $post, $thread );
    }

    return $self->_write_opening_copy( $command, $post, $thread );
}

sub _create_opening ( $self, $command, $thread ) {
    my $post = $self->schema->resultset('Post')->create( $command->{post} );

    return $self->_write_opening_copy( $command, $post, $thread );
}

# The opening post's body and revision and the thread's reply counter, and
# the post pointed at the body and the revision. A counter already there is
# the thread's own, from an earlier run, and is kept. Returns the rows and
# the command as written, with any id given up and replaced.
sub _write_opening_copy ( $self, $command, $post, $thread ) {
    $command = $self->_stored_part( $command, 'body' );
    $command = $self->_stored_part( $command, 'revision' );

    my ( $counted, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $self->schema,
        sub {
            return $self->schema->resultset('ThreadCounter')
              ->create( $command->{counter} );
        }
    );
    if ( !$counted && !_conflict($error)->on($COUNTER_ID_CONSTRAINT) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    _update_row(
        $post,
        {
            current_body_id     => $command->{body}{body_id},
            current_revision_id => $command->{revision}{revision_id},
        }
    );

    return { command => $command, post => $post, thread => $thread };
}

# Inserts the command's body or revision in a savepoint. A row of the same id
# already stored for the same post is an earlier run's and is kept; an id
# taken by another post's row is given up for a new one, once. Returns the
# command as written.
sub _stored_part ( $self, $command, $kind ) {
    my $rows = $self->schema->resultset( $PART{$kind}{source} );
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $rows->create( $command->{$kind} ); } );
    return $command if $created;
    if ( !_conflict($error)->on( $PART{$kind}{constraint} ) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    my $id_column = "${kind}_id";
    my $stored = $rows->find( { $id_column => $command->{$kind}{$id_column} } );
    return $command
      if _belongs( $stored, post_id => $command->{$kind}{post_id} );

    my $retry = $self->_with_new_id( $command, $kind );
    $self->_once_more( sub { return $rows->create( $retry->{$kind} ); } );

    return $retry;
}

# A new thread's events: thread.created, the post.created it causes, and the
# thread's audit row, under one correlation id. An earlier run's leftover
# records nothing.
sub _finish_new_thread ( $self, $created ) {
    return $created if $created->{skipped};

    my $input = {
        command        => $created->{command},
        correlation_id => $self->id_service->uuid,
    };
    my $thread_event = $self->recorder->record_event(
        %{ $self->events->thread_envelope( q{thread.created}, $input ) } );
    $self->recorder->record_event(
        %{
            $self->events->post_envelope( q{post.created},
                { %{$input}, causation_id => $thread_event->{event_id} } )
        }
    );
    $self->recorder->record_audit(
        %{ $self->events->thread_audit( q{thread.created}, $input ) } );

    return $created;
}

sub _leftover ( $command, $post, $thread ) {
    return {
        command => $command,
        post    => $post,
        skipped => 1,
        thread  => $thread,
    };
}

# The same command's thread: there, in the same category, with the same
# slug.
sub _same_thread ( $thread, $command ) {
    return _belongs( $thread, category_id => $command->{thread}{category_id} )
      && _belongs( $thread, slug => $command->{thread}{slug} );
}

# The command with a new id for a thread, post, body or revision, in every
# part that carries it.
sub _with_new_id ( $self, $command, $kind ) {
    my $id_column = "${kind}_id";
    my $id        = $self->id_service->uuid;
    my %retry     = %{$command};
    for my $part ( @{ $PART{$kind}{holders} } ) {
        $retry{$part} = { %{ $command->{$part} }, $id_column => $id };
    }
    return \%retry;
}

# A write tried once more in a savepoint after an id was given up; a second
# conflict is rethrown.
sub _once_more ( $self, $code ) {
    my ( $done, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema, $code );
    return $done if $done;

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

# The unique conflict an attempt ended in; any other error is rethrown.
sub _conflict ($error) {
    my $conflict = GPForum::X::Conflict->caught($error);
    if ( !$conflict ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $conflict;
}

# A row or undef, never an empty list.
sub _find_post ( $self, $post_id ) {
    my $post =
      $self->schema->resultset('Post')->find( { post_id => $post_id } );

    return $post;
}

# A title edit, a move, a delete or a restore, in one transaction: the
# thread checked under its row lock, then changed, its version bumped, and
# the event and audit row recorded. A write that would change nothing is
# skipped.
sub _write ( $self, $event_type, $command ) {
    return $self->schema->txn_do(
        sub {
            my ( $existing, $refused ) =
              $self->_checked_thread( $event_type, $command );
            return { ok => 0, error => $refused } if $refused;

            my $changes = $self->_changes( $event_type, $existing, $command );
            return _skipped_thread($existing) if !$changes;

            my $thread = _update_row( $existing,
                { %{$changes}, version => _next_version($existing) } );
            $self->_record( $event_type,
                { command => $command, thread => $thread } );

            return { ok => 1, thread => $thread };
        }
    );
}

# The workflow checked the thread before this row lock; a moderator may have
# locked or hidden it since, or its author deleted or restored it in another
# tab. The lock orders the write against those writes, which take FOR UPDATE
# too, and returns the thread as they committed it: the write's rule
# (GPForum::Domain::Thread) is asked again of it, as the workflow asked it of
# the thread as its reader showed it. A schema whose storage gives no handle
# has no lock to read back, and the rule is asked of the row found.
sub _checked_thread ( $self, $event_type, $command ) {
    my $write     = $WRITE{$event_type};
    my $rule      = $write->{rule};
    my $writer    = $command->{thread}{ $write->{writer} };
    my $thread_id = $command->{thread}{thread_id};

    my $refused;
    my $dbh = GPForum::Infrastructure::Storage->dbh_of( $self->schema );
    if ($dbh) {
        $refused = GPForum::Domain::Thread->$rule(
            GPForum::Domain::Thread->shown_to_writer(
                $dbh->selectrow_hashref( $THREAD_LOCK_SQL, undef, $thread_id ),
                $writer
            ),
            $writer
        );
    }
    my $existing = $self->_find_thread($thread_id);
    $refused //= GPForum::Domain::Thread->$rule( $existing, $writer );

    return ( $existing, $refused );
}

# What the write sets on the thread, or undef when the thread already has
# it. A move adds the category it leaves to the command, for its event.
sub _changes ( $self, $event_type, $existing, $command ) {
    my $wanted = $command->{thread};
    if ( $event_type eq 'thread.updated' ) {
        return undef
          if _belongs( $existing, title => $wanted->{title} )
          && _belongs( $existing, slug  => $wanted->{slug} );

        return { slug => $wanted->{slug}, title => $wanted->{title} };
    }
    if ( $event_type eq 'thread.moved' ) {
        return undef
          if _belongs( $existing, category_id => $wanted->{category_id} );

        $wanted->{previous_category_id} = _column( $existing, 'category_id' );
        return { category_id => $wanted->{category_id} };
    }

    my $deleting = $event_type eq 'thread.deleted';
    return {
        deleted_at => $deleting ? $self->clock->now_iso8601 : undef,
        deleted_by => $deleting ? $wanted->{deleted_by}     : undef,
    };
}

# A row or undef, never an empty list.
sub _find_thread ( $self, $thread_id ) {
    my $thread =
      $self->schema->resultset('Thread')->find( { thread_id => $thread_id } );

    return $thread;
}

# Whether a row is there and its column holds this value (undef as empty).
sub _belongs ( $row, $column, $value ) {
    return 0 if !$row;

    return ( _column( $row, $column ) // q{} ) eq ( $value // q{} ) ? 1 : 0;
}

sub _skipped_thread ($thread) {
    return {
        ok      => 1,
        skipped => 1,
        thread  => $thread,
    };
}

sub _next_version ($thread) {
    my $version = _column( $thread, 'version' ) || 1;

    return $version + 1;
}

sub _update_row ( $row, $changes ) {
    if ( ref $row eq 'HASH' ) {
        @{$row}{ keys %{$changes} } = values %{$changes};

        return $row;
    }

    $row->update($changes);

    return $row;
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

# The event and the audit row of one write, under one correlation id.
sub _record ( $self, $event_type, $input ) {
    $input->{correlation_id} = $self->id_service->uuid;
    $self->recorder->record_event(
        %{ $self->events->thread_envelope( $event_type, $input ) } );
    $self->recorder->record_audit(
        %{ $self->events->thread_audit( $event_type, $input ) } );

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Forum::ThreadStore - Write a new thread, and its title edits, moves, deletes and restores.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $store = GPForum::Service::Forum::ThreadStore->new(
        clock      => $clock,
        id_service => $id_service,
        schema     => $schema,
    );

    # The command GPForum::Service::Forum::ThreadComposer->prepare built.
    my $created = $store->create_thread($command);
    my $thread  = $created->{thread};

    my $edited = $store->edit_thread($title_command);
    if ( !$edited->{ok} ) {
        # $edited->{error} is 'thread not found' or 'thread is locked'
    }

    $store->move_thread($move_command);
    $store->delete_thread(
        {
            idempotency_key => $key,
            thread          => {
                category_id => $category_id,
                deleted_by  => $user_id,
                thread_id   => $thread_id,
            },
        }
    );

=head1 DESCRIPTION

The write side of a thread for L<GPForum::Service::Forum::PostingWorkflow>.
It takes the commands L<GPForum::Service::Forum::ThreadComposer> builds,
and the delete and restore commands the workflow builds itself, and writes
each in one transaction, together with its events (in the event log, each
with its outbox message) and its audit row, recorded through
L<GPForum::Infrastructure::EventRecorder>.

A new thread is five rows: the thread, its opening post, the post's body,
its first revision and the thread's reply counter; the post is then pointed
at its body and revision. Each insert runs through
L<GPForum::Infrastructure::UniqueConflict>, under a savepoint inside a live
PostgreSQL transaction, so a primary-key conflict does not abort the
transaction. A conflicting row that belongs to this same command (a thread
with the same category and slug, a post in the same thread, a body or a
revision of the same post, or the thread's counter) is the leftover of an
earlier attempt: it is reused and the rows still missing are inserted after
it. A conflict with another row's id is retried once with a fresh UUID.
When the earlier attempt's thread and opening post are found, nothing more
is written and the answer is marked C<skipped>. Events are recorded only
when this call inserted the thread row.

A title edit, a move, a delete and a restore first lock the thread's row
(C<SELECT ... FOR UPDATE>). The workflow checked the thread before the
transaction; a moderator may have locked or hidden it since, or its author
deleted or restored it in another tab. The lock orders the write against
those writes, which lock the row too, and the store asks the thread as they
left it the rule the workflow asked:
L<GPForum::Domain::Thread/edit_refusal> for a title edit, a move and a
delete, L<GPForum::Domain::Thread/restore_refusal> for a restore, of the
thread as L<GPForum::Domain::Thread/shown_to_writer> shows it to the
writer. A thread that is missing, hidden (in a moderation state other than
C<visible> and C<locked>), deleted by someone else, or in the wrong
deletion state -- deleted, for a title edit, a move or a delete, even to its
author; live, for a restore -- is C<thread not found>; one the writer did
not start is C<not the thread author>; and a locked one, deleted or not, is
C<thread is locked>. A refusal is returned, not thrown, and nothing is
written. Each change increments the thread's C<version>.

The envelopes and audit rows are built by L<GPForum::Service::Forum::Event>.
Every event's idempotency key is C<command:KEY:TYPE> when the command has an
C<idempotency_key>, and C<TYPE:AGGREGATE_ID> otherwise.

=head1 SUBROUTINES/METHODS

=head2 new

Constructor (L<GPForum::Base>). C<schema> is required (without it C<new>
throws L<GPForum::X::Argument>): the L<DBIx::Class> schema, or an in-memory
double with C<txn_do> and C<resultset>. C<clock> defaults to
L<GPForum::Service::Clock>, C<id_service> to L<GPForum::Infrastructure::Id>,
C<events> to L<GPForum::Service::Forum::Event>, and C<recorder> to a
L<GPForum::Infrastructure::EventRecorder> on the same id service and
schema.

=head2 create_thread

Takes the command L<GPForum::Service::Forum::ThreadComposer/prepare> builds:
a hash reference with C<idempotency_key> and the C<thread>, C<post>,
C<body>, C<revision> and C<counter> records. In one transaction it inserts
them as described above and then, only when it inserted the thread row,
records the C<thread.created> event, the C<post.created> event it causes,
and the C<thread.created> audit row, under one new correlation id.

Returns C<< { ok => 1, thread => $thread, post => $post, skipped => $skipped } >>,
where C<$thread> and C<$post> are the rows written or found, and C<$skipped>
is true when an earlier attempt had already written them. It never returns a
refusal: it dies, and the transaction rolls back, when an insert fails for
any reason other than the conflicts it resolves, or when the retry with a
fresh id fails too.

=head2 edit_thread

Takes the command L<GPForum::Service::Forum::ThreadComposer/prepare_title>
builds: C<idempotency_key> and
C<< thread => { thread_id, title, slug, editor_user_id } >>. In one
transaction, under the thread's row lock, it returns the refusals described
above as C<< { ok => 0, error => $message } >>, the editor being the
writer. When the title and the slug are both unchanged it writes nothing
and returns C<< { ok => 1, skipped => 1, thread => $thread } >>. Otherwise
it sets the title and the slug, records the C<thread.updated> event and
audit row, and returns C<< { ok => 1, thread => $thread } >> with the
updated row.

=head2 delete_thread

Takes C<idempotency_key> and
C<< thread => { thread_id, deleted_by, category_id } >>. In one transaction,
under the thread's row lock, it returns the refusals described above, the
deleter being the writer. Otherwise it sets C<deleted_at> to the clock's
now and C<deleted_by>, records the C<thread.deleted> event and audit row
(with the thread's category, from the row or else from the command), and
returns C<< { ok => 1, thread => $thread } >>.

=head2 restore_thread

Takes C<idempotency_key> and
C<< thread => { thread_id, restored_by, author_user_id, category_id } >>.
In one transaction, under the thread's row lock, it returns the refusals
described above, the restorer being the writer. Otherwise it clears
C<deleted_at> and C<deleted_by>, records the C<thread.undeleted> event and
audit row, and returns C<< { ok => 1, thread => $thread } >>.

=head2 move_thread

Takes the command L<GPForum::Service::Forum::ThreadComposer/prepare_move>
builds: C<idempotency_key> and
C<< thread => { thread_id, category_id, editor_user_id } >>. In one
transaction, under the thread's row lock, it returns the refusals of
L</edit_thread>, and C<< { ok => 1, skipped => 1, thread => $thread } >>,
writing nothing, when it is already in that category. Otherwise it adds the
current category to the command as C<previous_category_id> in its C<thread>
record (the command is changed in place), sets the new category, records the
C<thread.moved> event and audit row with both categories, and returns
C<< { ok => 1, thread => $thread } >>. Whether the target category exists
and the mover may read it is checked by the workflow, not here.

=head1 DIAGNOSTICS

Refusals are returned as C<< { ok => 0, error => $message } >>, with the
messages of L<GPForum::Domain::Thread>: C<thread not found>,
C<not the thread author>, C<thread is hidden> (only through a storage with
no handle, see L</BUGS AND LIMITATIONS>) and C<thread is locked>.
L<GPForum::Service::Forum::PostingWorkflow> answers them with
L<GPForum::Domain::Thread/status_of>, as it answers its own check.
Everything else dies and rolls the transaction back: a database error, a
unique violation on a constraint the store does not resolve, a second
conflict after the retry with a fresh id, or a failure to record an event
or an audit row.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Base>, L<GPForum::Domain::Thread>,
L<GPForum::Infrastructure::EventRecorder>,
L<GPForum::Infrastructure::Storage>, L<GPForum::X::Conflict>,
L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::Infrastructure::Row>,
L<GPForum::Infrastructure::Id>, L<GPForum::Service::Clock>,
L<GPForum::Service::Forum::Event>, L<Const::Fast>, L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Conflicts are told apart by the constraint the server names
(C<threads_pkey>, C<posts_pkey>, C<post_bodies_pkey>,
C<post_revisions_pkey>, C<thread_counters_pkey>), asked through
L<GPForum::X::Conflict/on>, so a driver must report it the way PostgreSQL
does. A schema whose storage gives no DBI handle takes no row lock: the rule
is asked of the row the write finds, as it is, without
L<GPForum::Domain::Thread/shown_to_writer>, so a hidden thread there is
C<thread is hidden> rather than not found. A handle that is given must
answer C<selectrow_hashref> as DBI does: the thread's row lock, which reads
back its C<author_user_id>, C<deleted_at>, C<locked_at> and
C<moderation_state>, is read through it.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
