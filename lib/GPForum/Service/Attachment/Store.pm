# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Attachment::Store;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Attachment::DownloadAccess;
use GPForum::Service::Attachment::Event;
use GPForum::Service::Attachment::Lifecycle;
use GPForum::Service::Attachment::Record;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $STATE_DELETED             => 'deleted';
const my $STATE_UPLOADED            => 'uploaded';
const my $SCAN_PENDING              => 'pending';
const my $FORMAT_CHECK              => 'format-check';
const my $SCAN_ERROR_LENGTH         => 500;
const my $SCAN_CLEAN                => 'clean';
const my $STATE_AVAILABLE           => 'available';
const my $ID_CONSTRAINT             => 'attachments_pkey';
const my $KEY_CONSTRAINT            => 'attachments_object_key_key';
const my $LINK_ID_CONSTRAINT        => 'attachment_links_pkey';
const my $LINK_TARGET_CONSTRAINT    => 'attachment_links_target_key';
const my $VARIANT_ID_CONSTRAINT     => 'attachment_variants_pkey';
const my $VARIANT_KEY_CONSTRAINT    => 'attachment_variants_variant_key';
const my $VARIANT_OBJECT_CONSTRAINT => 'attachment_variants_object_key_key';

has clock      => sub { return GPForum::Service::Clock->new; };
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
has schema      => undef;
has record      => sub { return GPForum::Service::Attachment::Record->new; };
has readability => undef;
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

sub create_intent ( $self, $intent ) {
    my $result = $self->schema->txn_do(
        sub {
            return $self->_persist_intent($intent);
        }
    );

    return _intent_result($result);
}

sub _persist_intent ( $self, $intent ) {
    my $existing = $self->_existing_intent($intent);
    if ($existing) {
        return $self->_existing_or_reissue( $existing, $intent );
    }

    return $self->_insert_or_reuse_intent($intent);
}

sub _existing_or_reissue ( $self, $existing, $intent ) {
    if ( $self->_same_object_key( $existing, $intent ) ) {
        return $self->_finish_leftover_intent( $existing, $intent );
    }

    return $self->_insert_or_reuse_intent( $self->_reissued_intent($intent) );
}

sub _same_object_key ( $self, $existing, $intent ) {
    my $stored    = $self->record->column( $existing, 'object_key' ) || q{};
    my $candidate = $intent->{object_key}                            || q{};

    return length $stored && $stored eq $candidate ? 1 : 0;
}

sub _insert_or_reuse_intent ( $self, $intent ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_intent($intent); },
      );
    if ($created) {
        return $created;
    }

    return $self->_intent_after_conflict( $intent, $error );
}

sub _intent_after_conflict ( $self, $intent, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_intent_after_unique( $intent, $error );
}

sub _intent_after_unique ( $self, $intent, $error ) {
    if ( _attachment_id_conflict($error) ) {
        return $self->_retry_or_reuse_id($intent);
    }
    if ( _object_key_conflict($error) ) {
        return $self->_reuse_object_key( $intent, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _retry_or_reuse_id ( $self, $intent ) {
    my $existing = $self->_existing_intent($intent);
    if ( $self->_reusable_intent( $existing, $intent ) ) {
        return $self->_finish_leftover_intent( $existing, $intent );
    }

    return $self->_retry_attachment_id($intent);
}

sub _reusable_intent ( $self, $existing, $intent ) {
    if ( !$existing ) {
        return 0;
    }

    return $self->_same_object_key( $existing, $intent );
}

sub _retry_attachment_id ( $self, $intent ) {
    my ( $created, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $self->schema,
        sub {
            return $self->_insert_intent( $self->_reissued_intent($intent) );
        },
    );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _reissued_intent ( $self, $intent ) {
    my $attachment_id = $self->id_service->uuid;

    return {
        %{$intent},
        attachment_id => $attachment_id,
        object_key    => $self->_object_key_for( $intent, $attachment_id ),
    };
}

sub _object_key_for ( $self, $intent, $attachment_id ) {
    return join q{/}, 'attachments', $intent->{owner_user_id}, $attachment_id;
}

sub _reuse_object_key ( $self, $intent, $error ) {
    my $existing =
      $self->_single_row( 'Attachment',
        { object_key => $intent->{object_key} } );
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_finish_leftover_intent( $existing, $intent );
}

sub _attachment_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _object_key_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $KEY_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _existing_intent ( $self, $intent ) {
    return $self->find_attachment( $intent->{attachment_id} );
}

sub _intent_result ($result) {
    my $payload = { ok => 1, attachment => $result->{attachment} };
    if ( $result->{skipped} ) {
        $payload->{skipped} = 1;
    }

    return $payload;
}

sub link_attachment ( $self, $input ) {
    my $existing = $self->_existing_link($input);
    if ($existing) {
        return $self->_idempotent_row($existing);
    }

    return $self->_insert_or_reuse_link($input);
}

sub _insert_or_reuse_link ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_link($input); },
      );
    if ($created) {
        return $created;
    }

    return $self->_link_after_conflict( $input, $error );
}

sub _link_after_conflict ( $self, $input, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_link_after_unique( $input, $error );
}

sub _link_after_unique ( $self, $input, $error ) {
    if ( _link_id_conflict($error) ) {
        return $self->_link_after_id_conflict($input);
    }
    if ( _link_target_conflict($error) ) {
        return $self->_reuse_link( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _link_after_id_conflict ( $self, $input ) {
    my $existing = $self->_existing_link($input);
    if ($existing) {
        return $self->_idempotent_row($existing);
    }

    return $self->_retry_link_id($input);
}

sub _retry_link_id ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_link($input); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _reuse_link ( $self, $input, $error ) {
    my $existing = $self->_existing_link($input);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_idempotent_row($existing);
}

sub _link_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $LINK_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _link_target_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $LINK_TARGET_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _create_link ( $self, $input ) {
    my $row = {
        attachment_id      => $input->{attachment_id},
        attachment_link_id => $self->id_service->uuid,
        created_at         => $self->clock->now_iso8601,
        target_id          => $input->{target_id},
        target_type        => $input->{target_type},
    };
    $self->schema->resultset('AttachmentLink')->create($row);

    return $row;
}

sub mark_uploaded ( $self, $attachment_id ) {
    my $attachment = $self->find_attachment($attachment_id);
    if ( !$attachment ) {
        my $undefined;
        return $undefined;
    }
    if ( $self->lifecycle->already_uploaded($attachment) ) {
        return $self->lifecycle->uploaded_replay($attachment);
    }

    return $self->_update_attachment(
        $attachment_id,
        {
            state       => $STATE_UPLOADED,
            uploaded_at => $self->clock->now_iso8601,
        }
    );
}

sub record_scan ( $self, $input ) {
    my $work = sub { return $self->_record_scan_once($input); };

    return $self->schema->can('txn_do')
      ? $self->schema->txn_do($work)
      : $work->();
}

# A verdict and its event are written together, in one transaction, and only
# over a row the verdict may replace (Lifecycle::replaceable_verdicts): never a
# deleted one, and never 'clean' over 'infected' or 'failed'. The condition is
# in the UPDATE itself, so when two scans race -- the outbox retry and the
# hourly rescan, say -- the database decides, and the loser is a replay.
sub _record_scan_once ( $self, $input ) {
    my $undefined;
    return $undefined if !$self->find_attachment( $input->{attachment_id} );

    my $changes = $self->lifecycle->scan_changes($input);
    my $updated = $self->_attachments->search_rs(
        {
            attachment_id => $input->{attachment_id},
            deleted_at    => undef,
            -or           =>
              $self->lifecycle->replaceable_verdicts( $input->{scan_status} ),
        }
    )->update($changes);

    # Numeric: DBI reports "no rows" as "0E0", which is true.
    if ( !( $updated + 0 ) ) {
        return $self->lifecycle->scanned_replay(
            $self->find_attachment( $input->{attachment_id} ) );
    }
    $self->_record_scan_event($input);

    return { attachment_id => $input->{attachment_id}, %{$changes} };
}

# Uploads no scanner has decided yet, oldest first: what the scheduled rescan
# retries once the antivirus answers again (ADR 0108).
sub pending_scan_ids ( $self, $limit ) {
    my $search = $self->_attachments->search_rs(
        {
            deleted_at  => undef,
            scan_status => $SCAN_PENDING,
            state       => $STATE_UPLOADED,
        },
        {
            columns  => ['attachment_id'],
            order_by => [
                { -asc => 'scan_attempts' },
                { -asc => 'uploaded_at' },
                { -asc => 'attachment_id' },
            ],
            rows => $limit,
        }
    );

    return [ map { $self->record->column( $_, 'attachment_id' ) }
          $self->record->rows($search) ];
}

# Files served on a format check alone, oldest first: the backfill's work
# once an antivirus is configured (ADR 0108).
sub unscanned_clean_ids ( $self, $limit ) {
    my $search = $self->_attachments->search_rs(
        _format_checked( { state => $STATE_AVAILABLE } ),
        {
            columns  => ['attachment_id'],
            order_by => [
                { -asc => 'scan_attempts' },
                { -asc => 'created_at' },
                { -asc => 'attachment_id' },
            ],
            rows => $limit,
        }
    );

    return [ map { $self->record->column( $_, 'attachment_id' ) }
          $self->record->rows($search) ];
}

# Records the engine that confirmed a format-checked file clean. Nothing else
# changes -- the file was already served -- and only a row still waiting for
# that confirmation is touched, so a quarantine that won a race stands.
sub confirm_clean ( $self, $input ) {
    my $updated = $self->_attachments->search_rs(
        _format_checked( { attachment_id => $input->{attachment_id} } ) )
      ->update(
        {
            scan_engine => $input->{scan_engine},
            scan_error  => undef,
            scanned_at  => $self->clock->now_iso8601,
        }
      );

    return {
        attachment_id => $input->{attachment_id},
        confirmed     => ( $updated + 0 ) ? 1 : 0,
        scan_engine   => $input->{scan_engine},
    };
}

# A scheduled scan that failed on this file: counted, with the error kept for
# the operator. The next runs take files with fewer attempts first.
sub record_scan_failure ( $self, $attachment_id, $error ) {
    my $attachment = $self->find_attachment($attachment_id);
    return 0 if !$attachment;

    my $attempts = $self->record->column( $attachment, 'scan_attempts' ) || 0;
    $attachment->update(
        {
            scan_attempts => $attempts + 1,
            scan_error    => substr( $error, 0, $SCAN_ERROR_LENGTH ),
        }
    );

    return 1;
}

sub _attachments ($self) {
    return $self->schema->resultset('Attachment');
}

sub _format_checked ($query) {
    return {
        %{$query},
        deleted_at  => undef,
        scan_status => $SCAN_CLEAN,
        -or => [ { scan_engine => undef }, { scan_engine => $FORMAT_CHECK } ],
    };
}

sub terminal_scan ( $self, $attachment ) {
    if ( !$self->lifecycle->already_scanned($attachment) ) {
        my $undefined;
        return $undefined;
    }

    return $self->lifecycle->scanned_replay($attachment);
}

sub find_variant ( $self, $input ) {
    return $self->_existing_variant($input);
}

sub add_variant ( $self, $input ) {
    my $existing = $self->find_variant($input);
    if ($existing) {
        return $self->_idempotent_row($existing);
    }

    return $self->_insert_or_reuse_variant($input);
}

sub _insert_or_reuse_variant ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_variant($input); },
      );
    if ($created) {
        return $created;
    }

    return $self->_variant_after_conflict( $input, $error );
}

sub _variant_after_conflict ( $self, $input, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_variant_after_unique( $input, $error );
}

sub _variant_after_unique ( $self, $input, $error ) {
    if ( _variant_id_conflict($error) ) {
        return $self->_variant_after_id_conflict($input);
    }
    if ( _variant_reuse_conflict($error) ) {
        return $self->_reuse_variant( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _variant_after_id_conflict ( $self, $input ) {
    my $existing = $self->find_variant($input);
    if ($existing) {
        return $self->_idempotent_row($existing);
    }

    return $self->_retry_variant_id($input);
}

sub _retry_variant_id ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_variant($input); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _reuse_variant ( $self, $input, $error ) {
    my $existing = $self->find_variant($input);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_idempotent_row($existing);
}

sub _variant_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $VARIANT_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _variant_reuse_conflict ($error) {
    if ( _variant_key_conflict($error) ) {
        return 1;
    }

    return _variant_object_conflict($error);
}

sub _variant_key_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $VARIANT_KEY_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _variant_object_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $VARIANT_OBJECT_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _create_variant ( $self, $input ) {
    my $row = {
        attachment_id         => $input->{attachment_id},
        attachment_variant_id => $self->id_service->uuid,
        byte_size             => $input->{byte_size},
        created_at            => $self->clock->now_iso8601,
        media_type            => $input->{media_type},
        object_key            => $input->{object_key},
        variant_type          => $input->{variant_type},
    };
    $self->schema->resultset('AttachmentVariant')->create($row);

    return $row;
}

sub _idempotent_row ( $self, $existing ) {
    return { %{ $self->record->row_hash($existing) }, idempotent => 1 };
}

sub find_attachment ( $self, $attachment_id ) {
    return $self->schema->resultset('Attachment')->find($attachment_id);
}

sub download_for ( $self, $input ) {
    my $attachment = $self->find_attachment( $input->{attachment_id} );
    my $denied     = $self->download_access->unavailable($attachment);
    if ($denied) {
        return $denied;
    }

    return $self->_authorized_download( $attachment, $input );
}

sub attachments_for_posts ( $self, $post_ids, $input ) {
    my %requested = map { $_ => 1 } @{$post_ids};
    my %by_post;
    for my $link ( $self->_post_links( [ keys %requested ] ) ) {
        $self->_append_post_attachment(
            {
                by_post        => \%by_post,
                link           => $link,
                requested      => \%requested,
                viewer         => $input->{viewer},
                viewer_user_id => $input->{viewer_user_id},
            }
        );
    }

    return \%by_post;
}

sub cleanup_orphans ( $self, $input ) {
    my @deleted;
    for my $attachment ( $self->_orphan_candidates($input) ) {
        my $row = $self->_delete_orphan( $attachment, $input );
        if ($row) {
            push @deleted, $row;
        }
    }

    return $self->lifecycle->cleanup_result( \@deleted );
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
    my $work = sub {
        return $self->_soft_delete_once( $attachment_id, $actor_id, $reason );
    };

    return $self->schema->can('txn_do')
      ? $self->schema->txn_do($work)
      : $work->();
}

sub _soft_delete_once ( $self, $attachment_id, $actor_id, $reason ) {
    my $attachment = $self->find_attachment($attachment_id);
    if ( !$attachment ) {
        return { error => 'not_found', ok => 0 };
    }
    if ( $self->lifecycle->already_deleted($attachment) ) {
        return $self->lifecycle->deleted_replay($attachment);
    }

    return $self->_delete_attachment( $attachment, $actor_id, $reason );
}

sub _existing_link ( $self, $input ) {
    return $self->_single_row(
        'AttachmentLink',
        {
            attachment_id => $input->{attachment_id},
            target_id     => $input->{target_id},
            target_type   => $input->{target_type},
        }
    );
}

sub _existing_variant ( $self, $input ) {
    my $existing = $self->_single_row(
        'AttachmentVariant',
        {
            attachment_id => $input->{attachment_id},
            variant_type  => $input->{variant_type},
        }
    );
    if ($existing) {
        return $existing;
    }

    return $self->_variant_by_object_key($input);
}

sub _variant_by_object_key ( $self, $input ) {
    my $object_key = $input->{object_key};
    if ( !defined $object_key || !length $object_key ) {
        my $undefined;
        return $undefined;
    }

    return $self->_single_row(
        'AttachmentVariant',
        {
            object_key => $object_key,
        }
    );
}

sub _authorized_download ( $self, $attachment, $input ) {
    return $self->download_access->authorized(
        {
            attachment     => $attachment,
            linked         => $self->_linked_targets($attachment),
            viewer         => $input->{viewer},
            viewer_user_id => $input->{viewer_user_id},
        }
    );
}

sub _linked_targets ( $self, $attachment ) {
    return [
        map { $self->_linked_target($_) } $self->_attachment_links(
            $self->record->column( $attachment, 'attachment_id' )
        )
    ];
}

sub _linked_target ( $self, $link ) {
    return {
        link   => $link,
        target => $self->_target_row(
            $self->record->column( $link, 'target_type' ),
            $self->record->column( $link, 'target_id' ),
        ),
    };
}

sub _post_links ( $self, $post_ids ) {
    my $search = $self->schema->resultset('AttachmentLink')->search_rs(
        {
            target_id   => { -in => $post_ids },
            target_type => $self->lifecycle->post_link_target,
        },
        { rows => $self->lifecycle->post_link_rows($post_ids) },
    );

    return $self->record->rows($search);
}

sub _append_post_attachment ( $self, $input ) {
    my $post_id = $self->record->column( $input->{link}, 'target_id' );
    if ( !$input->{requested}{$post_id} ) {
        my $undefined;
        return $undefined;
    }

    return $self->_push_visible_attachment( $input, $post_id );
}

sub _push_visible_attachment ( $self, $input, $post_id ) {
    my $decision = $self->download_for(
        {
            attachment_id =>
              $self->record->column( $input->{link}, 'attachment_id' ),

            # The request's resolved viewer: without it each attachment
            # resolved the reader again.
            viewer         => $input->{viewer},
            viewer_user_id => $input->{viewer_user_id},
        }
    );
    if ( !$decision->{ok} ) {
        return;
    }

    push @{ $input->{by_post}{$post_id} },
      $self->record->view( $decision->{attachment} );
    return;
}

sub _orphan_candidates ( $self, $input ) {
    my $search = $self->schema->resultset('Attachment')->search_rs(
        $self->lifecycle->orphan_where,
        $self->lifecycle->orphan_search_attrs($input),
    );

    return $self->record->rows($search);
}

sub _delete_orphan ( $self, $attachment, $input ) {
    my $undefined;

    if ( $self->_attachment_has_links($attachment) ) {
        return $undefined;
    }

    my $deleted = $self->soft_delete(
        $self->record->column( $attachment, 'attachment_id' ),
        $self->lifecycle->orphan_actor( $attachment, $input ),
        $self->lifecycle->orphan_reason($input),
    );
    if ( $deleted->{ok} ) {
        return $deleted->{attachment};
    }

    return $undefined;
}

sub _delete_attachment ( $self, $attachment, $actor_id, $reason ) {
    my $timestamp     = $self->clock->now_iso8601;
    my $attachment_id = $self->record->column( $attachment, 'attachment_id' );
    $attachment->update(
        {
            deleted_at => $timestamp,
            state      => $STATE_DELETED,
        }
    );

    return $self->_record_deletion(
        {
            actor_id      => $actor_id,
            attachment    => $attachment,
            attachment_id => $attachment_id,
            reason        => $reason,
            timestamp     => $timestamp,
        }
    );
}

sub _record_deletion ( $self, $input ) {
    my $row = {
        %{ $self->record->row_hash( $input->{attachment} ) },
        deleted_at => $input->{timestamp},
        state      => $STATE_DELETED,
    };
    my $correlation_id = $self->id_service->uuid;
    $self->_record_event(
        $self->events->envelope(
            {
                actor_id       => $input->{actor_id},
                attachment_id  => $input->{attachment_id},
                correlation_id => $correlation_id,
                event_type     => 'attachment.deleted',
                payload        => $self->events->deleted_payload($input),
            }
        )
    );
    $self->_record_audit(
        'attachment.deleted',
        {
            %{$row},
            owner_user_id => $input->{actor_id},
            reason        => $input->{reason},
        },
        $correlation_id
    );

    return { attachment => $row, ok => 1 };
}

sub _insert_intent ( $self, $intent ) {
    my $attachment = $self->schema->resultset('Attachment')->create($intent);
    $self->_write_intent_event($intent);

    return { attachment => $attachment };
}

sub _finish_leftover_intent ( $self, $existing, $intent ) {
    $self->_ensure_intent_write( $existing, $intent );

    return { attachment => $existing, skipped => 1 };
}

sub _ensure_intent_write ( $self, $existing, $intent ) {
    if ( $self->_intent_event_exists($existing) ) {
        return;
    }

    $self->_write_intent_event(
        {
            %{$intent},
            attachment_id =>
              $self->record->column( $existing, 'attachment_id' ),
        }
    );

    return;
}

sub _intent_event_exists ( $self, $existing ) {
    return $self->_single_row(
        'EventLog',
        {
            idempotency_key => join( q{:},
                'attachment.uploaded',
                $self->record->column( $existing, 'attachment_id' ) ),
        }
    );
}

sub _write_intent_event ( $self, $intent ) {
    my $correlation_id = $self->id_service->uuid;
    $self->_record_event(
        $self->events->envelope(
            {
                actor_id       => $intent->{owner_user_id},
                attachment_id  => $intent->{attachment_id},
                correlation_id => $correlation_id,
                event_type     => 'attachment.uploaded',
                payload        => $self->events->uploaded_payload($intent),
            }
        )
    );
    $self->_record_audit( 'attachment.uploaded', $intent, $correlation_id );

    return;
}

# A verdict is a system action. event_log.actor_id is a uuid, and the
# scanners are named, not users: a name there made PostgreSQL reject the
# insert, so every upload failed as it recorded its verdict. The actor stays
# NULL and the payload says which scanner decided (scanned_by).
sub _record_scan_event ( $self, $input ) {
    my $correlation_id = $self->id_service->uuid;
    $self->_record_event(
        $self->events->envelope(
            {
                actor_id       => undef,
                attachment_id  => $input->{attachment_id},
                correlation_id => $correlation_id,
                event_type     =>
                  $self->events->scan_event_type( $input->{scan_status} ),
                payload => $self->events->scan_payload($input),
            }
        )
    );

    return;
}

sub _update_attachment ( $self, $attachment_id, $changes ) {
    my $attachment = $self->find_attachment($attachment_id);
    if ( !$attachment ) {
        my $undefined;
        return $undefined;
    }

    $attachment->update($changes);

    return {
        attachment_id => $attachment_id,
        %{$changes},
    };
}

sub _attachment_links ( $self, $attachment_id ) {
    my $search = $self->schema->resultset('AttachmentLink')->search_rs(
        { attachment_id => $attachment_id },
        { rows          => $self->lifecycle->link_lookup_rows },
    );

    return $self->record->rows($search);
}

sub _attachment_has_links ( $self, $attachment ) {
    my @links = $self->_attachment_links(
        $self->record->column( $attachment, 'attachment_id' ) );

    return @links ? 1 : 0;
}

sub _target_row ( $self, $target_type, $target_id ) {
    my $undefined;

    my %resultset_for = (
        post   => 'Post',
        thread => 'Thread',
    );
    if ( !exists $resultset_for{$target_type} ) {
        return $undefined;
    }

    my $resultset =
      eval { return $self->schema->resultset( $resultset_for{$target_type} ); };
    if ( !$resultset ) {
        return $undefined;
    }

    return $resultset->find($target_id);
}

sub _single_row ( $self, $resultset_name, $query ) {
    my $search =
      $self->schema->resultset($resultset_name)
      ->search_rs( $query, { rows => 1 } );
    if ( $search->can('single') ) {
        return $search->single;
    }

    my @rows = $self->record->rows($search);
    return $rows[0];
}

sub _record_event ( $self, $event ) {
    $self->recorder->record_event( %{$event} );

    return;
}

sub _record_audit ( $self, $action, $intent, $correlation_id ) {
    $self->recorder->record_audit(
        %{ $self->events->audit( $action, $intent, $correlation_id ) } );

    return;
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
L<GPForum::Infrastructure::EventRecorder>.

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
L</unscanned_clean_ids> (ADR 0108).

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor. C<schema> is required. C<readability> (an object
with C<readable_by>, such as L<GPForum::Service::Forum::Readability>) is
optional; without it, downloads through a post or thread are decided on the
target's own visibility column. C<clock>, C<id_service>, C<recorder>,
C<record>, C<download_access>, C<lifecycle> and C<events> have defaults.

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

Takes a limit. Returns an array reference of the ids of undeleted
C<uploaded> attachments whose scan is still C<pending>, fewest scan
attempts first, then oldest upload, then id.

=head2 unscanned_clean_ids

Takes a limit. Returns an array reference of the ids of undeleted
C<available> attachments marked C<clean> on a format check alone (no scan
engine, or C<format-check>), fewest scan attempts first, then oldest, then
id.

=head2 confirm_clean

Takes a hash reference with C<attachment_id> and C<scan_engine>. Records the
engine that confirmed a format-checked file clean, clears C<scan_error> and
stamps C<scanned_at>; nothing else changes, since the file was already
served. Only a row still waiting for that confirmation is touched, so a
quarantine that won a race stands. Returns
C<< { attachment_id, confirmed => 1 or 0, scan_engine } >>.

=head2 record_scan_failure

Takes an attachment id and an error message. Adds one to C<scan_attempts>
and keeps the first 500 characters of the error in C<scan_error>. Returns 1,
or 0 for an unknown id.

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
one per linked attachment that L</download_for> lets the viewer have. The
link query is capped at ten rows per requested post. Posts without such
attachments have no key.

=head2 cleanup_orphans

Takes a hash reference with optional C<limit> (100), C<actor_id> (each
attachment's owner when absent) and C<reason> (C<orphan cleanup>).
Soft-deletes attachments still in the C<intent> state and without links,
oldest first, up to the limit, and returns
C<< { ok => 1, deleted => \@attachments } >>. The stored objects are not
removed here; L<GPForum::Service::Attachment::UploadPipeline> does that.

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
C<< { ok => 1, attachment => \%attachment } >>. An attachment already
deleted is returned with C<< idempotent => 1 >> and nothing written; an
unknown id returns C<< { ok => 0, error => 'not_found' } >>.

=head1 DIAGNOSTICS

Missing attachments, refused downloads and replays are returned, not
thrown. Database errors other than the handled unique conflicts are
rethrown, and a write inside a transaction rolls back.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Attachment::DownloadAccess>,
L<GPForum::Service::Attachment::Event>,
L<GPForum::Service::Attachment::Lifecycle>,
L<GPForum::Service::Attachment::Record>,
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
