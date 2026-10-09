# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::PostStore;

use Const::Fast;
use List::Util qw(max);
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Domain::Post;
use GPForum::Domain::Thread;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::PreparedQuery;
use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::Storage;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Forum::Event;
use GPForum::X::Conflict;

our $VERSION = '0.001';

const my $FIRST_POSITION     => 1;
const my $COUNTER_CONSTRAINT => 'thread_counters_pkey';

# The rows a post's write inserts by id, each with its result source, its
# primary key constraint, and the parts of a command that carry its id.
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
);

# FOR NO KEY UPDATE still queues behind another reply and behind the FOR
# UPDATE that moderation and thread edits take. Unlike FOR UPDATE it does not
# block the FOR KEY SHARE a foreign-key check takes, so a reader's first
# mark-read insert into thread_read_state does not wait for every reply in
# flight to commit. A locking read that waited returns the row as its holder
# committed it (READ COMMITTED), which is what the re-check needs.
const my $THREAD_LOCK_SQL => join q{ },
  'SELECT author_user_id, deleted_at, locked_at, moderation_state',
  'FROM threads WHERE thread_id = ? FOR NO KEY UPDATE';

# An author's edit, delete or restore of a post changes nothing on the thread
# row, so it takes the weakest lock that still queues behind the FOR UPDATE of
# moderation and of the thread's own writes (title, move, delete): it neither
# waits for replies nor holds them.
const my $POST_THREAD_LOCK_SQL => join q{ },
  'SELECT author_user_id, deleted_at, locked_at, moderation_state',
  'FROM threads WHERE thread_id = ? FOR KEY SHARE';
const my $POST_LOCK_SQL =>
  'SELECT post_id FROM posts WHERE post_id = ? FOR UPDATE';

# An author's delete and restore: who the command names as the writer, the
# rule the post is checked against, and what happens to the reply count.
const my %DELETION => (
    'post.deleted' => {
        delta  => -1,
        rule   => 'edit_refusal',
        writer => 'deleted_by',
    },
    'post.undeleted' => {
        delta  => 1,
        rule   => 'restore_refusal',
        writer => 'restored_by',
    },
);

__PACKAGE__->requires('schema');

has clock      => sub { return GPForum::Service::Clock->new; };
has prepared   => sub { return GPForum::Infrastructure::PreparedQuery->new; };
has id_service => sub {
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};
has events   => sub { return GPForum::Service::Forum::Event->new; };
has recorder => sub ($self) {
    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};

sub create_post ( $self, $command ) {
    my $result =
      $self->schema->txn_do( sub { return $self->_insert_post($command); } );

    # A refusal from under the thread lock has written nothing. Hand it back
    # as it is: folded into the answer below it would read as a success with
    # no post.
    return $result if exists $result->{ok} && !$result->{ok};

    return {
        ok      => 1,
        post    => $result->{post},
        skipped => $result->{skipped},
    };
}

sub edit_post ( $self, $command ) {
    return $self->schema->txn_do(
        sub { return $self->_update_post($command); } );
}

sub delete_post ( $self, $command ) {
    return $self->schema->txn_do(
        sub { return $self->_set_deleted( $command, 'post.deleted' ); } );
}

sub restore_post ( $self, $command ) {
    return $self->schema->txn_do(
        sub { return $self->_set_deleted( $command, 'post.undeleted' ); } );
}

# The thread row lock does two jobs. It hands out positions in commit order,
# which the PostReader keyset and the ReadState high-water mark depend on: a
# reply that commits later never takes a lower number. And it orders a reply
# against a moderator locking or hiding the thread, and against its author
# deleting it, so the thread is checked again here, as the lock returns it.
#
# A post id already taken by a post of the same thread is an earlier run of
# the same command, finished here; one taken by another thread's post gives
# its id up for a new one, once. Any other conflict -- a position taken
# meanwhile -- gets the position allocated again, once.
sub _insert_post ( $self, $command ) {
    my $refused = $self->_thread_refusal( $command->{post} );
    return $refused if $refused;

    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_reply($command); } );
    return $created if $created;
    if ( !_conflict($error)->on( $PART{post}{constraint} ) ) {
        return $self->_insert_reply( _unpositioned($command) );
    }

    my $post = $self->_find_post( $command->{post}{post_id} );
    if ( !_belongs( $post, thread_id => $command->{post}{thread_id} ) ) {
        my $retry = $self->_with_new_id( $command, 'post' );
        return $self->_once_more(
            sub { return $self->_insert_reply($retry); } );
    }

    my $body = $self->_find_body( $command->{body}{body_id} );
    if ( _belongs( $body, post_id => $command->{body}{post_id} ) ) {
        return { post => $post, skipped => 1 };
    }

    return $self->_finish_new_post(
        $self->_write_copy( { command => $command, post => $post } ) );
}

# The in-memory doubles have no handle, so nothing to lock or re-check. The
# workflow read the thread before this lock was granted, and a moderator may
# have locked or hidden it since, or its author deleted it: the same rule
# (GPForum::Domain::Thread) is asked again of the row the lock returns.
sub _thread_refusal ( $self, $post ) {
    my $dbh = GPForum::Infrastructure::Storage->dbh_of( $self->schema );
    return undef if !$dbh;

    my $error = GPForum::Domain::Thread->reply_refusal(
        GPForum::Domain::Thread->shown_to_writer(
            $dbh->selectrow_hashref(
                $THREAD_LOCK_SQL, undef, $post->{thread_id}
            ),
            $post->{author_user_id}
        )
    );

    return $error ? { ok => 0, error => $error } : undef;
}

sub _insert_reply ( $self, $command ) {
    $command = $self->_with_position($command);
    my $post = $self->schema->resultset('Post')->create( $command->{post} );

    return $self->_finish_new_post(
        $self->_write_copy( { command => $command, post => $post } ) );
}

# A new post's body and revision, its reply count, and the post pointed at
# both. Returns the command as written, with any id given up and replaced.
sub _write_copy ( $self, $ctx ) {
    my $command = $self->_stored_part( $ctx->{command}, 'body' );
    $command = $self->_stored_part( $command, 'revision' );
    $self->_count_replies( $command->{post}{thread_id}, 1 );
    _update_row(
        $ctx->{post},
        {
            current_body_id     => $command->{body}{body_id},
            current_revision_id => $command->{revision}{revision_id},
        }
    );

    return { command => $command, post => $ctx->{post} };
}

sub _finish_new_post ( $self, $ctx ) {
    $self->_record( 'post.created', { command => $ctx->{command} } );

    return { post => $ctx->{post} };
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

# The workflow checked the post and its thread inside the command's
# transaction but before any row lock, so a moderator may have locked the
# thread or hidden the post since, or the author deleted either. So the edit
# takes its rows under lock (see _locked_post) and asks the same rule
# (GPForum::Domain::Post) again of what the locks return.
sub _update_post ( $self, $command ) {
    my $editor = $command->{post}{editor_user_id};
    my ( $existing, $thread ) =
      $self->_locked_post( $command->{post}, $editor );
    my $refused =
      GPForum::Domain::Post->edit_refusal( $existing, $thread, $editor );
    return { ok => 0, error => $refused } if $refused;
    return _skipped($existing) if $self->_body_unchanged( $existing, $command );

    my ( $edited, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_write_revision( $existing, $command ); } );
    return $edited if $edited;

    return $self->_edit_after_conflict( $existing, $command, $error );
}

# A revision id already taken by a revision of the same post is an earlier run
# of the same command: finished when the post points at it already, else
# pointed at now. One taken by another post's revision gives its id up for a
# new one, once. Any other conflict -- a revision number taken meanwhile --
# gets the number allocated again, once.
sub _edit_after_conflict ( $self, $existing, $command, $error ) {
    if ( !_conflict($error)->on( $PART{revision}{constraint} ) ) {
        return $self->_write_revision( $existing, _unnumbered($command) );
    }

    my $revision_id = $command->{revision}{revision_id};
    my $stored      = $self->schema->resultset('PostRevision')
      ->find( { revision_id => $revision_id } );
    if ( !_belongs( $stored, post_id => $command->{revision}{post_id} ) ) {
        my $retry = $self->_with_new_id( $command, 'revision' );
        return $self->_once_more(
            sub { return $self->_write_revision( $existing, $retry ); } );
    }
    return _skipped($existing)
      if _belongs( $existing, current_revision_id => $revision_id );

    return $self->_finish_edit( $command,
        $self->_point_at( $existing, $command ) );
}

# The new body (or the post's own of the same id), the revision numbered
# after the post's highest, and the post pointed at both.
sub _write_revision ( $self, $existing, $command ) {
    $command =
      $self->_stored_part( $self->_with_revision_number($command), 'body' );
    $self->schema->resultset('PostRevision')->create( $command->{revision} );

    return $self->_finish_edit( $command,
        $self->_point_at( $existing, $command ) );
}

sub _finish_edit ( $self, $command, $post ) {
    $self->_record( 'post.updated', { command => $command, post => $post } );

    return { ok => 1, post => $post };
}

sub _point_at ( $self, $post, $command ) {
    return _update_row(
        $post,
        {
            current_body_id     => $command->{body}{body_id},
            current_revision_id => $command->{revision}{revision_id},
            version             => _next_version($post),
        }
    );
}

sub _body_unchanged ( $self, $post, $command ) {
    my $body_id = _column( $post, 'current_body_id' );
    return 0 if !_has_text($body_id);

    return _belongs( $self->_find_body($body_id),
        source_hash => $command->{body}{source_hash} );
}

# The workflow lets its author delete or restore a post only where it would
# let them edit it: a hidden post, or one in a locked thread, is refused
# (ADR 0061). A moderator may have hidden it or locked the thread after that
# check, so the store asks again under the same locks as an edit.
sub _set_deleted ( $self, $command, $event_type ) {
    my $deletion = $DELETION{$event_type};
    my $writer   = $command->{post}{ $deletion->{writer} };
    my $rule     = $deletion->{rule};
    my ( $existing, $thread ) =
      $self->_locked_post( $command->{post}, $writer );
    my $refused = GPForum::Domain::Post->$rule( $existing, $thread, $writer );
    return { ok => 0, error => $refused } if $refused;

    my $deleting = $deletion->{delta} < 0;
    my $post     = _update_row(
        $existing,
        {
            deleted_at => $deleting ? $self->clock->now_iso8601 : undef,
            deleted_by => $deleting ? $writer                   : undef,
            version    => _next_version($existing),
        }
    );
    my $thread_id =
      _column( $post, 'thread_id' ) || $command->{post}{thread_id};

    if ( _has_text($thread_id) && _is_reply($post) ) {
        $self->_count_replies( $thread_id, $deletion->{delta} );
    }
    $self->_record( $event_type, { command => $command, post => $post } );

    return { ok => 1, post => $post };
}

# The thread row, then the post row -- no write takes a post row before its
# thread's, so no cycle -- and the post, and the thread if the writer can
# still read it, as those locks return them. Every write the workflow's checks
# guard (lock, hide, delete, restore) takes one of these rows FOR UPDATE, so a
# check made under both sees it committed. A post never changes thread, so the
# thread the workflow read it in is the one to lock. The in-memory doubles
# have no handle and nothing to lock: an empty hash stands for a thread that
# is there and not locked.
sub _locked_post ( $self, $post, $writer ) {
    my $dbh    = GPForum::Infrastructure::Storage->dbh_of( $self->schema );
    my $thread = {};
    if ($dbh) {
        my $thread_id = $post->{thread_id}
          // _column( $self->_find_post( $post->{post_id} ), 'thread_id' );
        $thread = GPForum::Domain::Thread->shown_to_writer(
            $dbh->selectrow_hashref( $POST_THREAD_LOCK_SQL, undef, $thread_id ),
            $writer
        );
        $dbh->selectrow_array( $POST_LOCK_SQL, undef, $post->{post_id} );
    }

    return ( $self->_find_post( $post->{post_id} ), $thread );
}

# The reply count is the thread's thread_counters row (ADR 0119). The delta
# is added in SQL, and never takes the count below zero: a projection that
# drifted does not fail the write. The row is taken last, after the thread
# and the post, as every writer of it does, so no lock cycle. Replies hold
# the thread row already, so they never queue on this one for each other;
# a delete or a restore, which holds the thread row FOR KEY SHARE, queues
# on it with them. A thread without a row gets one, and an insert that
# loses that race adds the delta to the row that won.
sub _count_replies ( $self, $thread_id, $delta ) {
    my $counters = $self->schema->resultset('ThreadCounter');
    my $key      = { thread_id => $thread_id };
    my $counter  = $counters->find($key);
    if ( !$counter ) {
        my ( $created, $error ) =
          GPForum::Infrastructure::UniqueConflict->attempt(
            $self->schema,
            sub {
                return $counters->create(
                    { %{$key}, reply_count => max( $delta, 0 ) } );
            }
          );
        return undef if $created;

        my $conflict = _conflict($error);
        $counter = $counters->find($key);
        if ( !$counter || !$conflict->on($COUNTER_CONSTRAINT) ) {
            GPForum::Infrastructure::UniqueConflict->rethrow($error);
        }
    }
    if ( ref $counter eq 'HASH' ) {
        $counter->{reply_count} =
          max( ( $counter->{reply_count} // 0 ) + $delta, 0 );
        return undef;
    }

    $counter->update(
        { reply_count => \[ 'GREATEST(reply_count + ?, 0)', $delta ] } );

    return undef;
}

# The opening post is not a reply: deleting or restoring it leaves the
# count. A row without a position (the in-memory doubles) counts.
sub _is_reply ($post) {
    return ( _column( $post, 'position' ) // 0 ) == $FIRST_POSITION ? 0 : 1;
}

sub _with_position ( $self, $command ) {
    return $command if _valid_number( $command->{post}{position} );

    my $posts  = $self->schema->resultset('Post');
    my $latest = $posts->search_rs(
        { thread_id => $command->{post}{thread_id} },
        {
            order_by => [ { -desc => 'position' }, { -desc => 'post_id' } ],
            rows     => 1,
        }
    )->single;
    my $position =
      $latest ? _column( $latest, 'position' ) + 1 : $FIRST_POSITION;

    return { %{$command},
        post => { %{ $command->{post} }, position => $position } };
}

# The next revision number is found by reading every revision of the post.
sub _with_revision_number ( $self, $command ) {
    return $command if _valid_number( $command->{revision}{revision_number} );

    my $revisions = $self->schema->resultset('PostRevision')
      ->search_rs( { post_id => $command->{revision}{post_id} } );
    my $latest = max 0,
      map { _column( $_, 'revision_number' ) || 0 } $revisions->all;

    return { %{$command},
        revision =>
          { %{ $command->{revision} }, revision_number => $latest + 1 } };
}

sub _unpositioned ($command) {
    return { %{$command}, post => { %{ $command->{post} }, position => 0 } };
}

sub _unnumbered ($command) {
    return {
        %{$command},
        revision => { %{ $command->{revision} }, revision_number => 0 }
    };
}

# The command with a new id for a post, body or revision, in every part that
# carries it.
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

# The event and the audit row of one write, under one correlation id.
sub _record ( $self, $event_type, $input ) {
    $input->{correlation_id} = $self->id_service->uuid;
    $self->recorder->record_event(
        %{ $self->events->post_envelope( $event_type, $input ) } );
    $self->recorder->record_audit(
        %{ $self->events->post_audit( $event_type, $input ) } );

    return;
}

# A row or undef, never an empty list: these are read in list context. The
# post's id comes from the URL: one that is not a uuid finds nothing before
# any statement, where PostgreSQL refusing it failed the whole write.
sub _find_post ( $self, $post_id ) {
    return undef if !defined $post_id || !length $post_id;

    my $posts = $self->schema->resultset('Post');
    my $post  = $self->prepared->row(
        schema    => $self->schema,
        shape     => 'post:by-id',
        source    => 'Post',
        resultset => sub {
            return $posts->search_rs( { 'me.post_id' => $post_id } );
        },
        fallback =>
          sub { return [ $posts->find( { post_id => $post_id } ) // () ]; },
        values => { 'me.post_id' => $post_id },
    );

    return $post;
}

sub _find_body ( $self, $body_id ) {
    my $body =
      $self->schema->resultset('PostBody')->find( { body_id => $body_id } );

    return $body;
}

sub _skipped ($post) {
    return { ok => 1, post => $post, skipped => 1 };
}

sub _next_version ($post) {
    return ( _column( $post, 'version' ) || 1 ) + 1;
}

sub _update_row ( $row, $changes ) {
    if ( ref $row eq 'HASH' ) {
        @{$row}{ keys %{$changes} } = values %{$changes};

        return $row;
    }

    $row->update($changes);

    return $row;
}

# Whether a row is there and its column holds this value (undef as empty).
sub _belongs ( $row, $column, $value ) {
    return 0 if !$row;

    return ( _column( $row, $column ) // q{} ) eq ( $value // q{} ) ? 1 : 0;
}

sub _has_text ($value) {
    return defined $value && length $value ? 1 : 0;
}

sub _valid_number ($number) {
    return defined $number && $number > 0 ? 1 : 0;
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

1;

__END__

=head1 NAME

GPForum::Service::Forum::PostStore - Write replies, edits, deletes and restores of posts under row locks.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $store = GPForum::Service::Forum::PostStore->new(
        clock      => $clock,
        id_service => $id_service,
        schema     => $schema,
    );

    # A reply or an edit, as PostComposer prepared it.
    my $created = $store->create_post( $prepared->{command} );
    return $created->{error} if !$created->{ok};
    my $post = $created->{post};

    my $edited = $store->edit_post( $prepared_edit->{command} );

    $store->delete_post(
        {
            idempotency_key => $command_id,
            post            => {
                deleted_by => $user_id,
                post_id    => $post_id,
                thread_id  => $thread_id,
            },
        }
    );
    $store->restore_post(
        {
            idempotency_key => $command_id,
            post            => {
                author_user_id => $author_id,
                post_id        => $post_id,
                restored_by    => $user_id,
                thread_id      => $thread_id,
            },
        }
    );

=head1 DESCRIPTION

The write side of posts. L<GPForum::Service::Forum::PostingWorkflow> calls
it with the commands that L<GPForum::Service::Forum::PostComposer> builds
for a reply or an edit, and with the ones it builds itself for a delete or a
restore. Each method runs in its own C<txn_do> and, with one correlation
id, records through L<GPForum::Infrastructure::EventRecorder> the domain
event (C<post.created>, C<post.updated>, C<post.deleted>,
C<post.undeleted>, aggregate type C<post>) and the audit row of the same
name. The event's idempotency key is
C<command:IDEMPOTENCY_KEY:EVENT_TYPE> when the command carries an
C<idempotency_key>, C<EVENT_TYPE:POST_ID> otherwise.

A reply takes its thread row C<FOR NO KEY UPDATE>. The lock hands out
positions in commit order, which the post reader's keyset and the read-state
high-water mark depend on: a reply that commits later never takes a lower
number. It also orders the reply against a moderator locking or hiding the
thread and against its author deleting it. C<FOR NO KEY UPDATE> does not
block the C<FOR KEY SHARE> of a foreign-key check, so a reader's first
mark-read insert does not wait for the replies in flight. An edit, delete or
restore changes nothing on the thread row, so it takes the thread row
C<FOR KEY SHARE> and then the post row C<FOR UPDATE>: the thread before the
post, as every write does, so no lock cycle.

The workflow checked the thread and the post before those locks were
granted, so the store asks the same rules again of what the locks return:
L<GPForum::Domain::Thread> for a reply (C<shown_to_writer>, then
C<reply_refusal>) and L<GPForum::Domain::Post> for an edit or a delete
(C<edit_refusal>) and a restore (C<restore_refusal>). A missing thread, one
in a state the thread page does not show (only C<visible> and C<locked>
are), or a deleted one written to by anyone but its author is
C<thread not found>; a locked thread is C<thread is locked>. A missing
post is C<post not found>, and so is a deleted one for an edit or a delete
and one that is not deleted for a restore; a post by someone else is
C<not the post author>, which only a command the workflow did not build can
reach, since authorship never changes; a hidden post is C<post is hidden>.
A refusal is returned as C<< { ok => 0, error => MESSAGE } >> with nothing
written, and the workflow answers it with the status
L<GPForum::Domain::Post/status_of> gives, the status of its own check.

Unique conflicts are caught in a savepoint through
L<GPForum::Infrastructure::UniqueConflict>, and the
L<GPForum::X::Conflict> it returns is asked which key collided
(C<posts_pkey>, C<post_bodies_pkey>, C<post_revisions_pkey>,
C<thread_counters_pkey>); any other error is rethrown. The post, its body and its revision are each inserted in
a savepoint of their own. A post id already taken by a post of the same
thread, or a body or revision id already taken by a row of the same post, is
read as an earlier run of the same command and that row is kept; an id taken
by any other row is replaced with a new UUID, in every part of the command
that carries it, and the write is tried once more. Any other unique
conflict, such as a position or a revision number taken meanwhile, gets the
position or number allocated again, once.

The reply count is the C<reply_count> of the thread's C<thread_counters>
row (ADR 0119): a reply or a restore of a reply adds 1, a delete of one
subtracts 1, and the opening post (position 1) is not a reply, so its
delete and restore leave the count. The row is updated in SQL
(C<GREATEST(reply_count + ?, 0)>), so the count never goes below zero; it
is taken after the thread and post rows, as every writer of it takes it. A
thread without a row gets one, and an insert that loses a race updates the
row that won.

A schema with no DBI handle (the in-memory doubles) has nothing to lock:
the thread is not checked again, though an edit or a delete still refuses a
missing, deleted, someone else's or hidden post, and a restore a missing,
not deleted, someone else's or hidden one. Rows may then be plain hashes, which are updated in place.

=head1 SUBROUTINES/METHODS

=head2 new

Constructor (L<GPForum::Base>). C<schema>, the L<DBIx::Class> schema, is
required: without it L</new> throws L<GPForum::X::Argument>. C<clock> defaults to L<GPForum::Service::Clock> and stamps
C<deleted_at>; C<id_service> defaults to L<GPForum::Infrastructure::Id> and
mints the correlation ids and any replacement ids; C<recorder> defaults to
an L<GPForum::Infrastructure::EventRecorder> on that id service and
schema; C<events> defaults to L<GPForum::Service::Forum::Event>, which
builds the envelopes and audit rows the recorder is handed.

=head2 create_post

Takes the command from C<prepare> in L<GPForum::Service::Forum::PostComposer>:
C<post>, C<body>, C<revision> and C<idempotency_key>.
Under the thread lock it re-checks the thread for C<post>'s
C<author_user_id>, then inserts the post (at the thread's next position,
from 1, when C<position> is not a positive number), its body and its
revision, adds 1 to the thread's reply count, points the post at
the body and the revision, and records C<post.created>.

Returns C<< { ok => 0, error => 'thread not found' | 'thread is locked' } >>
when refused, else C<< { ok => 1, post => $post, skipped => $skipped } >>.
C<post> is the new post row. When C<post_id> is already a post of the same
thread whose body is stored too, that post is returned with C<skipped> 1 and
nothing is written or recorded; when its body is missing, the body,
revision, count and pointers are completed and recorded. Otherwise
C<skipped> is undefined.

=head2 edit_post

Takes the command from C<prepare_revision> in
L<GPForum::Service::Forum::PostComposer>: C<post> (C<post_id>,
C<thread_id>, C<editor_user_id>), C<body>, C<revision> and
C<idempotency_key>. Under the thread and post locks it re-checks the post
and its thread for the editor. When the C<source_hash> of the new body is
that of the post's current body, it writes nothing. Otherwise it stores the
body (reusing a stored body of the same id and post), inserts the revision
(numbered after the post's highest when C<revision_number> is not a
positive number), points the post at both, raises its C<version> and
records C<post.updated>. A stored revision of the same id and post that the
post does not point at yet is pointed at and recorded instead.

Returns a refusal (C<post not found>, C<thread not found>,
C<not the post author>, C<post is hidden>, C<thread is locked>),
C<< { ok => 1, post => $post } >>
after a write, or C<< { ok => 1, post => $post, skipped => 1 } >> when the
body was unchanged or the post already points at the command's revision
(an earlier run of the same command).

=head2 delete_post

Takes C<< { idempotency_key, post => { post_id, thread_id, deleted_by } } >>.
Under the thread and post locks it re-checks the post and its thread for
C<deleted_by>, then sets C<deleted_at> (the clock's ISO 8601 time) and
C<deleted_by>, raises the post's C<version>, subtracts 1 from the
thread's reply count unless the post is the opening one (the post's
thread, else C<thread_id>; skipped when neither is set) and records
C<post.deleted>.

Returns a refusal (C<post not found>, C<thread not found>,
C<not the post author>, C<post is hidden>, C<thread is locked>) or
C<< { ok => 1, post => $post } >>.
A post already deleted is C<post not found>: replaying a command is the
workflow's command idempotency, not the store's.

=head2 restore_post

Takes C<< { idempotency_key, post => { post_id, thread_id, restored_by,
author_user_id } } >>. Under the thread and post locks it requires the post
to be deleted and re-checks it and its thread for C<restored_by>, then
clears C<deleted_at> and C<deleted_by>, raises the post's C<version>, adds
1 to the thread's reply count unless the post is the opening one (skipped
when no thread id is known) and
records C<post.undeleted>, whose payload carries the post's author (the
row's, else C<author_user_id>).

Returns a refusal (C<post not found> when the post is missing or not
deleted, C<thread not found>, C<not the post author>, C<post is hidden>,
C<thread is locked>) or
C<< { ok => 1, post => $post } >>.

=head1 DIAGNOSTICS

A refusal is returned, not thrown: C<< { ok => 0, error => MESSAGE } >>
with C<thread not found>, C<thread is locked>, C<post not found>,
C<not the post author> or C<post is hidden>. Database errors die, and so does a unique conflict that
is not one of those described above or that the one retry does not
resolve (the L<GPForum::X::Conflict> re-thrown with C<croak>); the
transaction rolls back. A store built without a C<schema> throws
L<GPForum::X::Argument>.
L<GPForum::Service::Forum::PostingWorkflow> catches the death, logs it and
answers C<post store failed>.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>, L<GPForum::Base>, L<Const::Fast>, L<List::Util>,
L<GPForum::Domain::Post>, L<GPForum::Domain::Thread>,
L<GPForum::Infrastructure::EventRecorder>, L<GPForum::Infrastructure::Id>,
L<GPForum::Infrastructure::Row>, L<GPForum::Infrastructure::Storage>,
L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::Service::Clock>,
L<GPForum::Service::Forum::Event>, L<GPForum::X::Conflict>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Each retry happens once: a second conflict on a new post id, or on a
position or revision number allocated again, dies and rolls the transaction
back. A second conflict on a new body or revision id is passed up and taken
as a position conflict (a reply) or a revision number conflict (an edit),
so the write is tried once more from there. The next revision
number is found by reading every revision of the post. Without a DBI handle
nothing is locked and the thread is not checked again.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
