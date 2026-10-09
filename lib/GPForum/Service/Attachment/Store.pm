# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Attachment::Store;

use Const::Fast;
use List::Util qw(any);
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::PreparedQuery;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Attachment::DownloadAccess;
use GPForum::Service::Attachment::Event;
use GPForum::Service::Attachment::Lifecycle;
use GPForum::Service::Attachment::Record;
use GPForum::Service::Attachment::ScanQueue;
use GPForum::Service::Clock;
use GPForum::X::Conflict;

our $VERSION = '0.001';

const my $STATE_DELETED             => 'deleted';
const my $STATE_UPLOADED            => 'uploaded';
const my $ID_CONSTRAINT             => 'attachments_pkey';
const my $KEY_CONSTRAINT            => 'attachments_object_key_key';
const my $LINK_ID_CONSTRAINT        => 'attachment_links_pkey';
const my $LINK_TARGET_CONSTRAINT    => 'attachment_links_target_key';
const my $VARIANT_ID_CONSTRAINT     => 'attachment_variants_pkey';
const my $VARIANT_KEY_CONSTRAINT    => 'attachment_variants_variant_key';
const my $VARIANT_OBJECT_CONSTRAINT => 'attachment_variants_object_key_key';
const my $LTE                       => q{<} . q{=};
const my $NO_STORAGE                => 'no attachment storage';
const my %TARGET_RESULTSET          => ( post => 'Post', thread => 'Thread' );

# Correlated on the candidate, so PostgreSQL answers it with the links' unique
# index (attachment_id first) as an anti-join.
const my $UNLINKED => join q{ },
  'NOT EXISTS (SELECT 1 FROM attachment_links',
  'WHERE attachment_links.attachment_id = me.attachment_id)';

has clock      => sub { return GPForum::Service::Clock->new; };
has prepared   => sub { return GPForum::Infrastructure::PreparedQuery->new; };
has id_service => sub {
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};
has recorder => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
__PACKAGE__->requires(qw(schema));
has record      => sub { return GPForum::Service::Attachment::Record->new; };
has readability => undef;    # optional: DownloadAccess's, optional there

# The attachment storage (FilesystemStorage, or anything with delete_object):
# the orphan purge removes the files with the rows, and does nothing without
# it.
has storage => undef;    # optional: without one orphan cleanup is skipped

has download_access => sub {
    my ($self) = @_;

    return GPForum::Service::Attachment::DownloadAccess->new(
        readability => $self->readability,
        record      => $self->record,
    );
};
has lifecycle => sub {
    my ($self) = @_;

    return GPForum::Service::Attachment::Lifecycle->new(
        clock  => $self->clock,
        record => $self->record,
    );
};
has events => sub {
    my ($self) = @_;

    return GPForum::Service::Attachment::Event->new(
        id_service => $self->id_service, );
};

# The rescan's and the backfill's queues (ADR 0108), answered here for the
# scanner and the scheduled jobs.
has scan_queue => sub {
    my ($self) = @_;

    return GPForum::Service::Attachment::ScanQueue->new(
        clock  => $self->clock,
        record => $self->record,
        schema => $self->schema,
    );
};

sub create_intent ( $self, $intent ) {
    my $result = $self->schema->txn_do(
        sub {
            return $self->_persist_intent($intent);
        }
    );

    return {
        ok         => 1,
        attachment => $result->{attachment},
        ( $result->{skipped} ? ( skipped => 1 ) : () ),
    };
}

# An intent that finds its attachment, or loses the race to insert it, under
# the same object key finishes that one: the writer that stored it stopped
# short of its event, and the event and audit row are written now, once.
# Under another key -- the id was issued twice -- it is issued a fresh id and
# key, before the insert or after the conflict on the id. So is one whose id
# conflicted although the look after the conflict found no row under it (a
# snapshot older than the holder's commit): the same id would only conflict
# again.
sub _persist_intent ( $self, $intent ) {
    return $self->_insert_once(
        {
            create => sub {
                my $attachment = $self->_attachments->create($intent);
                $self->_write_intent_event($intent);
                return { attachment => $attachment };
            },
            find => sub ( $on_key, $conflicted ) {
                return $self->_single_row( 'Attachment',
                    { object_key => $intent->{object_key} } )
                  if $on_key;

                my $taken = $self->find_attachment( $intent->{attachment_id} );
                return undef if !$taken && !$conflicted;
                my $stored =
                  ( $taken && $self->record->column( $taken, 'object_key' ) )
                  || q{};
                return $taken
                  if length $stored
                  && $stored eq ( $intent->{object_key} || q{} );

                my $attachment_id = $self->id_service->uuid;
                $intent = {
                    %{$intent},
                    attachment_id => $attachment_id,
                    object_key    => join( q{/},
                        'attachments', $intent->{owner_user_id},
                        $attachment_id ),
                };
                return undef;
            },
            id_constraint   => $ID_CONSTRAINT,
            key_constraints => [$KEY_CONSTRAINT],
            reuse           => sub ($existing) {
                my $attachment_id =
                  $self->record->column( $existing, 'attachment_id' );
                my $recorded = $self->_single_row(
                    'EventLog',
                    {
                        idempotency_key => join q{:},
                        'attachment.uploaded',
                        $attachment_id
                    }
                );
                if ( !$recorded ) {
                    $self->_write_intent_event(
                        { %{$intent}, attachment_id => $attachment_id } );
                }
                return { attachment => $existing, skipped => 1 };
            },
        }
    );
}

sub link_attachment ( $self, $input ) {
    return $self->_insert_once(
        {
            create => sub {
                return $self->_create_row( 'AttachmentLink',
                    'attachment_link_id',
                    { %{$input}{qw(attachment_id target_id target_type)} } );
            },
            find            => sub { return $self->_existing_link($input); },
            id_constraint   => $LINK_ID_CONSTRAINT,
            key_constraints => [$LINK_TARGET_CONSTRAINT],
        }
    );
}

# An intent, link or variant row, inserted unless an equivalent one is there:
# find, asked first and again after a unique conflict (told whether the
# conflict was on a key, and that there was one), names it, and reuse
# answers with it -- by default as an idempotent replay. An id that collides
# is drawn again, once: create draws a fresh one each call, or find reissues
# it.
sub _insert_once ( $self, $spec ) {
    my $reuse = $spec->{reuse}
      || sub ($row) { return $self->_idempotent_row($row) };
    my $existing = $spec->{find}->( 0, 0 );
    return $reuse->($existing) if $existing;

    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $spec->{create} );
    return $created if $created;

    my $conflict = GPForum::X::Conflict->caught($error);
    my $on_key =
      $conflict && any { $conflict->on($_) } @{ $spec->{key_constraints} };
    if ( !$on_key && !( $conflict && $conflict->on( $spec->{id_constraint} ) ) )
    {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    $existing = $spec->{find}->( $on_key, 1 );
    return $reuse->($existing) if $existing;
    if ($on_key) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $spec->{create} );
    return $created if $created;

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

# A link or variant row under an id drawn on each call, as _insert_once
# expects of create.
sub _create_row ( $self, $resultset, $id_column, $columns ) {
    my $row = {
        %{$columns},
        $id_column => $self->id_service->uuid,
        created_at => $self->clock->now_iso8601,
    };
    $self->schema->resultset($resultset)->create($row);

    return $row;
}

sub mark_uploaded ( $self, $attachment_id ) {
    my $attachment = $self->find_attachment($attachment_id);
    return undef if !$attachment;
    if ( $self->lifecycle->already_uploaded($attachment) ) {
        return $self->lifecycle->uploaded_replay($attachment);
    }

    my $changes = {
        state       => $STATE_UPLOADED,
        uploaded_at => $self->clock->now_iso8601,
    };
    $attachment->update($changes);

    return { attachment_id => $attachment_id, %{$changes} };
}

# A verdict and its event are written together, in one transaction, and only
# over a row the verdict may replace (Lifecycle::replaceable_verdicts): never a
# deleted one, and never 'clean' over 'infected' or 'failed'. The condition is
# in the UPDATE itself, so when two scans race -- the outbox retry and the
# hourly rescan, say -- the database decides, and the loser is a replay.
#
# A verdict is a system action. event_log.actor_id is a uuid, and the
# scanners are named, not users: a name there made PostgreSQL reject the
# insert, so every upload failed as it recorded its verdict. The actor stays
# NULL and the payload says which scanner decided (scanned_by).
sub record_scan ( $self, $input ) {
    my $attachment_id = $input->{attachment_id};

    return $self->_in_transaction(
        sub {
            return undef if !$self->find_attachment($attachment_id);

            my $changes = $self->lifecycle->scan_changes($input);
            my $updated = $self->_attachments->search_rs(
                {
                    attachment_id => $attachment_id,
                    deleted_at    => undef,
                    -or           => $self->lifecycle->replaceable_verdicts(
                        $input->{scan_status}
                    ),
                }
            )->update($changes);

            # Numeric: DBI reports "no rows" as "0E0", which is true.
            if ( !( $updated + 0 ) ) {
                return $self->lifecycle->scanned_replay(
                    $self->find_attachment($attachment_id) );
            }
            $self->_record(
                {
                    actor_id      => undef,
                    attachment_id => $attachment_id,
                    event_type    =>
                      $self->events->scan_event_type( $input->{scan_status} ),
                    payload => $self->events->scan_payload($input),
                }
            );

            return { attachment_id => $attachment_id, %{$changes} };
        }
    );
}

sub pending_scan_ids ( $self, $limit ) {
    return $self->scan_queue->pending_scan_ids($limit);
}

sub unscanned_clean_ids ( $self, $limit ) {
    return $self->scan_queue->unscanned_clean_ids($limit);
}

sub confirm_clean ( $self, $input ) {
    return $self->scan_queue->confirm_clean($input);
}

sub record_scan_failure ( $self, $attachment_id, $error ) {
    return $self->scan_queue->record_scan_failure( $attachment_id, $error );
}

sub _attachments ($self) {
    return $self->schema->resultset('Attachment');
}

sub terminal_scan ( $self, $attachment ) {
    return $self->lifecycle->already_scanned($attachment)
      ? $self->lifecycle->scanned_replay($attachment)
      : undef;
}

# The variant of this type, or else the one already holding the object key.
sub find_variant ( $self, $input ) {
    my $existing = $self->_single_row(
        'AttachmentVariant',
        {
            attachment_id => $input->{attachment_id},
            variant_type  => $input->{variant_type},
        }
    );
    return $existing if $existing;

    my $object_key = $input->{object_key};
    return undef if !defined $object_key || !length $object_key;

    return $self->_single_row( 'AttachmentVariant',
        { object_key => $object_key } );
}

sub add_variant ( $self, $input ) {
    my @columns =
      qw(attachment_id byte_size media_type object_key variant_type);

    return $self->_insert_once(
        {
            create => sub {
                return $self->_create_row( 'AttachmentVariant',
                    'attachment_variant_id', { %{$input}{@columns} } );
            },
            find            => sub { return $self->find_variant($input); },
            id_constraint   => $VARIANT_ID_CONSTRAINT,
            key_constraints =>
              [ $VARIANT_KEY_CONSTRAINT, $VARIANT_OBJECT_CONSTRAINT ],
        }
    );
}

sub _idempotent_row ( $self, $existing ) {
    return { %{ $self->lifecycle->row_columns($existing) }, idempotent => 1 };
}

# The row by its id, through a statement built once; an id that is not
# one finds nothing before any statement is sent.
sub find_attachment ( $self, $attachment_id ) {
    return undef if !defined $attachment_id || !length $attachment_id;

    my $attachments = $self->_attachments;

    return $self->prepared->row(
        schema    => $self->schema,
        shape     => 'attachment:by-id',
        source    => 'Attachment',
        resultset => sub {
            return $attachments->search_rs(
                { 'me.attachment_id' => $attachment_id } );
        },
        fallback =>
          sub { return [ $attachments->find($attachment_id) // () ]; },
        values => { 'me.attachment_id' => $attachment_id },
    );
}

sub download_for ( $self, $input ) {
    my $attachment = $self->find_attachment( $input->{attachment_id} );
    my $denied     = $self->download_access->unavailable($attachment);
    return $denied if $denied;

    my @links = $self->_attachment_links(
        $self->record->column( $attachment, 'attachment_id' ) );
    return $self->download_access->authorized(
        {
            attachment => $attachment,
            linked     => [
                map {
                    +{
                        link   => $_,
                        target => $self->_target_row(
                            $self->record->column( $_, 'target_type' ),
                            $self->record->column( $_, 'target_id' ),
                        ),
                    }
                } @links
            ],
            viewer         => $input->{viewer},
            viewer_user_id => $input->{viewer_user_id},
        }
    );
}

sub attachments_for_posts ( $self, $post_ids, $input ) {
    my %requested = map { $_ => 1 } @{$post_ids};
    my @ids       = sort keys %requested;
    my $links     = $self->schema->resultset('AttachmentLink');
    my $listed    = sub {
        return $links->search_rs(
            {
                'me.target_id'   => { -in => \@ids },
                'me.target_type' => $self->lifecycle->post_link_target,
            },
            { rows => $self->lifecycle->post_link_rows( \@ids ) },
        );
    };

    # One statement per page size: the page's post ids fill the IN list.
    my $rows = $self->prepared->rows(
        schema    => $self->schema,
        shape     => 'attachment_links:posts:' . scalar @ids,
        source    => 'AttachmentLink',
        resultset => $listed,
        fallback  => sub { return [ $self->record->rows( $listed->() ) ]; },
        values    => {
            'me.target_id' => \@ids,
            limit          => $self->lifecycle->post_link_rows( \@ids ),
        },
    );
    my %by_post;
    for my $link ( @{$rows} ) {
        my $post_id = $self->record->column( $link, 'target_id' );
        next if !$requested{$post_id};

        my $decision = $self->download_for(
            {
                attachment_id =>
                  $self->record->column( $link, 'attachment_id' ),

                # The request's resolved viewer: without it each attachment
                # resolved the reader again.
                viewer         => $input->{viewer},
                viewer_user_id => $input->{viewer_user_id},
            }
        );
        next if !$decision->{ok};

        # The decision's own columns: its attachment is a copy
        # Record::row_hash made of a DBIx::Class row, and came back empty, so
        # a thread page listed each file without its id or its name.
        push @{ $by_post{$post_id} }, $self->record->view($decision);
    }

    return \%by_post;
}

# Uploads that never completed: intents nobody linked, old enough not to be
# an upload still in flight (Lifecycle::orphan_min_age). Each one's files go
# before its row (_purge_orphan). A deleted row is never selected again, so
# the files of a purge that failed after the delete would stay in storage for
# good. Without a storage there is no way to remove the files, and the rows
# stay where the next run finds them. One orphan that fails is reported and
# left; the others are purged all the same.
#
# Orphans only, so the row cap counts orphans: the linked intents and the
# young ones used to be fetched and skipped, and enough of them at the head of
# the queue kept every run from reaching an orphan behind them.
sub cleanup_orphans ( $self, $input ) {
    if ( !$self->storage ) {
        return {
            %{ $self->lifecycle->cleanup_result( [] ) },
            skipped => $NO_STORAGE
        };
    }

    my $candidates = $self->_attachments->search_rs(
        {
            %{ $self->lifecycle->orphan_where },
            created_at => { $LTE => $self->lifecycle->orphan_cutoff($input) },
            -and       => [ \$UNLINKED ],
        },
        $self->lifecycle->orphan_search_attrs($input),
    );
    my ( @deleted, @errors );
    for my $attachment ( $self->record->rows($candidates) ) {
        try {
            my $row = $self->_purge_orphan( $attachment, $input );
            if ($row) {
                push @deleted, $row;
            }
        }
        catch ($error) {
            push @errors, join q{: },
              $self->record->column( $attachment, 'attachment_id' ),
              _error_reason($error);
        };
    }

    return $self->lifecycle->cleanup_result( \@deleted, \@errors );
}

sub delete_linked ( $self, $input ) {
    if ( !$self->_existing_link($input) ) {
        return { error => 'not_found', ok => 0 };
    }

    return $self->soft_delete(
        $input->{attachment_id},
        $input->{actor_id}, $self->lifecycle->author_delete_reason($input),
    );
}

sub soft_delete ( $self, $attachment_id, $actor_id, $reason ) {
    return $self->_in_transaction(
        sub {
            my $attachment = $self->find_attachment($attachment_id);
            return { error => 'not_found', ok => 0 } if !$attachment;
            if ( $self->lifecycle->already_deleted($attachment) ) {
                return $self->lifecycle->deleted_replay($attachment);
            }

            return $self->_delete_attachment( $attachment, $actor_id, $reason );
        }
    );
}

sub _in_transaction ( $self, $work ) {
    return $self->schema->can('txn_do')
      ? $self->schema->txn_do($work)
      : $work->();
}

sub _existing_link ( $self, $input ) {
    return $self->_single_row( 'AttachmentLink',
        { %{$input}{qw(attachment_id target_id target_type)} } );
}

# Under the row's lock (FOR UPDATE, which a link's foreign-key check waits
# on), and asked again once it is held: a run that got there first has
# deleted the row, and a link committed while this run waited keeps it, so
# two runs at once purge an orphan once, and the files of an attachment just
# linked are not removed. The files go before the row, inside the
# transaction: one rolled back after the removal leaves the row for the next
# run, whose removals find nothing and succeed. The variants' objects go
# first, then the original's; removing an object that is not there is not an
# error, so a run that repeats a removal does no harm.
sub _purge_orphan ( $self, $attachment, $input ) {
    my $attachment_id = $self->record->column( $attachment, 'attachment_id' );

    return $self->schema->txn_do(
        sub {
            my $locked =
              $self->_attachments->find( $attachment_id, { for => 'update' } );
            return undef
              if !$locked || !$self->lifecycle->still_intent($locked);
            my @links = $self->_attachment_links($attachment_id);
            return undef if @links;

            my $variants =
              $self->schema->resultset('AttachmentVariant')->search_rs(
                { attachment_id => $attachment_id },
                { columns       => ['object_key'] }
              );
            for my $object ( $self->record->rows($variants), $locked ) {
                $self->storage->delete_object(
                    $self->record->column( $object, 'object_key' ) );
            }

            return $self->_delete_attachment(
                $locked,
                $self->lifecycle->orphan_actor( $locked, $input ),
                $self->lifecycle->orphan_reason($input),
            )->{attachment};
        }
    );
}

# The reason alone: the first line, without the " at FILE line N." that croak
# and then txn_do's rethrow each add, nor the "{UNKNOWN}: " the rethrow puts
# before an error that is not a DBIx::Class one.
sub _error_reason ($error) {
    my ($line) = split /\n/msx, $error // q{};
    return q{} if !defined $line;
    $line =~ s/\A [{] UNKNOWN [}] : \s+//msx;
    $line =~ s/(?: \s+ at \s+ \S+ \s+ line \s+ \d+ [.]? )+ \s* \z//msx;

    return $line;
}

sub _delete_attachment ( $self, $attachment, $actor_id, $reason ) {
    my $timestamp     = $self->clock->now_iso8601;
    my $attachment_id = $self->record->column( $attachment, 'attachment_id' );
    my $deletion      = { deleted_at => $timestamp, state => $STATE_DELETED };
    $attachment->update($deletion);

    my $row = { %{ $self->lifecycle->row_columns($attachment) }, %{$deletion} };
    $self->_record(
        {
            actor_id      => $actor_id,
            attachment_id => $attachment_id,
            event_type    => 'attachment.deleted',
            payload       => $self->events->deleted_payload(
                { attachment_id => $attachment_id, reason => $reason }
            ),
        },
        { %{$row}, owner_user_id => $actor_id, reason => $reason },
    );

    return { attachment => $row, ok => 1 };
}

sub _write_intent_event ( $self, $intent ) {
    $self->_record(
        {
            actor_id      => $intent->{owner_user_id},
            attachment_id => $intent->{attachment_id},
            event_type    => 'attachment.uploaded',
            payload       => $self->events->uploaded_payload($intent),
        },
        $intent,
    );

    return;
}

# The event, and the audit row (for the event's own action) when there is
# one, under one correlation id.
sub _record ( $self, $event, $audit = undef ) {
    my $correlation_id = $self->id_service->uuid;
    $self->recorder->record_event(
        %{
            $self->events->envelope(
                { %{$event}, correlation_id => $correlation_id }
            )
        }
    );
    if ($audit) {
        $self->recorder->record_audit(
            %{
                $self->events->audit( $event->{event_type}, $audit,
                    $correlation_id )
            }
        );
    }

    return;
}

sub _attachment_links ( $self, $attachment_id ) {
    my $search = $self->schema->resultset('AttachmentLink')->search_rs(
        { attachment_id => $attachment_id },
        { rows          => $self->lifecycle->link_lookup_rows },
    );

    return $self->record->rows($search);
}

sub _target_row ( $self, $target_type, $target_id ) {
    return undef if !exists $TARGET_RESULTSET{$target_type};

    my $resultset;
    try {
        $resultset =
          $self->schema->resultset( $TARGET_RESULTSET{$target_type} );
    }
    catch ($error) {
        return undef;
    };

    return $resultset ? $resultset->find($target_id) : undef;
}

sub _single_row ( $self, $resultset_name, $query ) {
    my $search =
      $self->schema->resultset($resultset_name)
      ->search_rs( $query, { rows => 1 } );
    return $search->single if $search->can('single');

    my @rows = $self->record->rows($search);
    return $rows[0];
}

1;

__END__

=head1 NAME

GPForum::Service::Attachment::Store - Attachment rows, links, variants, scan verdicts and deletions.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $store = GPForum::Service::Attachment::Store->new(
        readability => GPForum::Service::Forum::Readability->new(
            schema => $schema,
        ),
        schema => $schema,
    );

    $store->create_intent($intent);    # from IntentBuilder
    $store->mark_uploaded( $intent->{attachment_id} );
    $store->record_scan(
        {
            actor_id      => 'antivirus',
            attachment_id => $intent->{attachment_id},
            scan_engine   => 'clamd',
            scan_status   => 'clean',
        }
    );
    $store->link_attachment(
        {
            attachment_id => $intent->{attachment_id},
            target_id     => $post_id,
            target_type   => 'post',
        }
    );

    my $download = $store->download_for(
        {
            attachment_id  => $attachment_id,
            viewer         => $viewer,
            viewer_user_id => $user_id,
        }
    );
    my $by_post = $store->attachments_for_posts( \@post_ids,
        { viewer => $viewer, viewer_user_id => $user_id } );

=head1 DESCRIPTION

The persistence of attachments. An upload goes through the states
C<intent>, C<uploaded>, then C<available> or C<quarantined> on its scan
verdict, and C<deleted> when it is removed; only an C<available>, C<clean>,
undeleted attachment is ever served. Links tie an attachment to a post, a
thread or a profile, and variants (such as a thumbnail) are further objects
derived from it. The storage of the bytes is elsewhere
(L<GPForum::Service::Attachment::FilesystemStorage>); this class writes rows
and the events and audit entries that go with them, through
L<GPForum::Infrastructure::EventRecorder>, and asks the storage only to
remove the files of the orphans it purges (L</cleanup_orphans>).

Every write can be repeated. Intents, links and variants are found before
they are inserted and inserted under savepoints through
L<GPForum::Infrastructure::UniqueConflict>, so a retry or a concurrent
writer ends on the row that is already there, reported with
C<< idempotent => 1 >> or C<< skipped => 1 >>; a conflict on a generated id
is retried once with a fresh id.

A scan verdict and its event are written in one transaction, and only over
a row the verdict may replace: never a deleted one, and never C<clean> over
C<infected> or C<failed>, while a verdict other than C<clean> may replace
C<clean>, so a later scan can quarantine a file that was being served. The
condition is in the C<UPDATE> itself, so when two scans race (the outbox
retry and the hourly rescan) the database decides and the loser is a
replay. Verdicts are recorded with no actor, because the scanners are not
users; the event payload names the scanner.

The rescan and the backfill of files served on a format check alone, once
an antivirus is configured, take their work from L</pending_scan_ids> and
L</unscanned_clean_ids> (ADR 0108), which
L<GPForum::Service::Attachment::ScanQueue> answers.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor. C<schema> is required. C<readability> (an object
with C<readable_by>, such as L<GPForum::Service::Forum::Readability>) is
optional; without it, downloads through a post or thread are decided on the
target's own visibility column. C<storage> (an object with
C<delete_object>, such as L<GPForum::Service::Attachment::FilesystemStorage>)
is optional, and L</cleanup_orphans> does nothing without it. C<clock>,
C<id_service>, C<recorder>, C<record>, C<download_access>, C<lifecycle>,
C<events> and C<scan_queue> (a L<GPForum::Service::Attachment::ScanQueue>
on the same schema, clock and record) have defaults.

=head2 create_intent

Takes an intent hash reference as built by
L<GPForum::Service::Attachment::IntentBuilder> (C<attachment_id>,
C<owner_user_id>, C<object_key>, C<original_filename>, C<media_type>,
C<byte_size>, C<checksum>, C<< state => 'intent' >>,
C<< scan_status => 'pending' >> and the timestamps). In a transaction,
inserts the attachment and records its C<attachment.uploaded> event and
audit entry. Returns C<< { ok => 1, attachment => $row } >>.

When the id is already taken by a row with the same object key, the
existing row is returned with C<< skipped => 1 >>, and its event and audit
are written first if they are missing. When the id is taken by a row with a
different object key, the intent is reissued with a fresh id and the object
key C<< attachments/<owner_user_id>/<new id> >>.

=head2 mark_uploaded

Takes an attachment id. Moves an C<intent> attachment to C<uploaded> and
stamps C<uploaded_at>; returns C<< { attachment_id, state, uploaded_at } >>.
An attachment past the C<intent> state is left alone and returned as
C<< { attachment_id, idempotent => 1, state, uploaded_at } >>. Returns
C<undef> for an unknown id.

=head2 record_scan

Takes a hash reference with C<attachment_id>, C<scan_status> (C<clean> or
another verdict), C<scan_engine> and the optional C<scan_signature>,
C<reason> and C<actor_id> (the scanner's name, put in the event payload as
C<scanned_by>). In a transaction, a C<clean> verdict makes the attachment
C<available>; any other makes it C<quarantined> and stamps
C<quarantined_at>. It records C<attachment.scanned> or
C<attachment.quarantined> and returns
C<< { attachment_id, scan_status, scan_engine, scan_signature, scan_error => undef, scanned_at, state } >>
(plus C<quarantined_at>). When the row may not take the verdict, nothing is
written and it returns C<< { attachment_id, idempotent => 1, scan_status, state } >>
with the stored values. Returns C<undef> for an unknown id.

=head2 terminal_scan

Takes an attachment row. Returns
C<< { attachment_id, idempotent => 1, scan_status, state } >> when its scan
is final (C<clean> and C<available>, or C<infected> and C<quarantined>),
otherwise C<undef>.

=head2 pending_scan_ids

As L<GPForum::Service::Attachment::ScanQueue/pending_scan_ids>.

=head2 unscanned_clean_ids

As L<GPForum::Service::Attachment::ScanQueue/unscanned_clean_ids>.

=head2 confirm_clean

As L<GPForum::Service::Attachment::ScanQueue/confirm_clean>.

=head2 record_scan_failure

As L<GPForum::Service::Attachment::ScanQueue/record_scan_failure>.

=head2 link_attachment

Takes a hash reference with C<attachment_id>, C<target_type> and
C<target_id>. Inserts the link and returns its hash
(C<attachment_link_id>, C<attachment_id>, C<target_type>, C<target_id>,
C<created_at>), or the existing link's columns with C<< idempotent => 1 >>
when the attachment is already linked to that target.

=head2 find_variant

Takes a hash reference with C<attachment_id>, C<variant_type> and an
optional C<object_key>. Returns the attachment's variant of that type, else
the variant stored under that object key, else C<undef>.

=head2 add_variant

Takes a hash reference with C<attachment_id>, C<variant_type>,
C<object_key>, C<media_type> and C<byte_size>. Inserts the variant and
returns its hash (with C<attachment_variant_id> and C<created_at>), or the
existing variant's columns with C<< idempotent => 1 >> when
L</find_variant> finds one.

=head2 find_attachment

Takes an attachment id. Returns the C<Attachment> row, or C<undef>.

=head2 download_for

Takes a hash reference with C<attachment_id>, C<viewer> and
C<viewer_user_id>. Returns C<< { ok => 0, error => 'not_found' } >> when the
attachment is missing, deleted, not C<available> or not C<clean>. Otherwise
L<GPForum::Service::Attachment::DownloadAccess> decides from the
attachment's links: an unlinked attachment, or one linked to a profile, is
served to its owner only; one linked to a post or thread is served only
when the target is present and visible, and then to a viewer who can read
it or to the owner.
Returns C<< { ok => 0, error => 'forbidden' } >> when no link allows it, or
C<< { ok => 1, attachment, attachment_id, byte_size, media_type, object_key, original_filename } >>.

=head2 attachments_for_posts

Takes an array reference of post ids and a hash reference with C<viewer>
and C<viewer_user_id>. Returns a hash reference from post id to an array
reference of C<< { attachment_id, byte_size, media_type, original_filename } >>,
one per linked attachment that L</download_for> lets the viewer have, read
from the download decision's own columns. The link query is capped at ten
rows per requested post. Posts without such attachments have no key.

=head2 cleanup_orphans

Takes a hash reference with optional C<limit> (100), C<min_age> in seconds
(one day), C<actor_id> (each attachment's owner when absent) and C<reason>
(C<orphan cleanup>). Purges the orphans: attachments still in the C<intent>
state, without links, and created at least C<min_age> ago -- younger, an
intent may be an upload still in flight -- oldest first, up to the limit,
which counts orphans only.

Each orphan is purged in a transaction of its own, under its row's lock
(C<SELECT ... FOR UPDATE>), and only if, once the lock is held, it is still
an intent without links: two runs at once purge it once, and an attachment
linked while the run waited keeps its files. It removes the stored object of
every variant and then the attachment's own object through C<storage>, and
then soft-deletes the row as L</soft_delete> does, recording the deletion in
the actor's name for the reason. The files go first: a deleted row is never
selected again, while a row left by a purge that failed after the removal is
purged by the next run, whose removals find nothing and succeed. The variant
rows stay with the soft-deleted attachment.

Returns C<< { ok => 1, deleted => \@attachments } >>, the columns of each
attachment this run deleted. An orphan that could not be purged -- a file
the storage would not remove, a lock not had within the database's
C<lock_timeout> -- is left as it is, and the run goes on to the next and
returns C<< ok => 0 >> with C<errors>, one C<< "<attachment_id>: <reason>" >>
each. Without a C<storage> nothing is purged, and it returns
C<< { ok => 1, deleted => [], skipped => 'no attachment storage' } >>.

=head2 delete_linked

Takes a hash reference with C<attachment_id>, C<target_type>,
C<target_id>, C<actor_id> and an optional C<reason> (C<author delete>).
Soft-deletes the attachment when it is linked to that target; otherwise
returns C<< { ok => 0, error => 'not_found' } >>. Whether the actor may
delete it is the caller's decision.

=head2 soft_delete

Takes an attachment id, an actor id and a reason. In a transaction, sets
C<state> to C<deleted>, stamps C<deleted_at> and records an
C<attachment.deleted> event and audit entry; returns
C<< { ok => 1, attachment => \%attachment } >>, the attachment's columns as
they now are. An attachment already deleted is returned, with its columns,
with C<< idempotent => 1 >> and nothing written; an unknown id returns
C<< { ok => 0, error => 'not_found' } >>.

=head1 DIAGNOSTICS

Missing attachments, refused downloads and replays are returned, not
thrown. Database errors other than the handled unique conflicts are
rethrown, and a write inside a transaction rolls back. L</cleanup_orphans>
alone catches what fails for one orphan, storage and database errors alike,
and reports it in C<errors>.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Attachment::DownloadAccess>,
L<GPForum::Service::Attachment::Event>,
L<GPForum::Service::Attachment::Lifecycle>,
L<GPForum::Service::Attachment::Record>,
L<GPForum::Service::Attachment::ScanQueue>,
L<GPForum::Infrastructure::EventRecorder>,
L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::Infrastructure::Id>,
L<GPForum::Service::Clock>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
