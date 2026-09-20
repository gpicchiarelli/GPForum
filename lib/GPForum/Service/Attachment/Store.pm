package GPForum::Service::Attachment::Store;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

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
const my $ID_CONSTRAINT             => 'attachments_pkey';
const my $KEY_CONSTRAINT            => 'attachments_object_key_key';
const my $LINK_ID_CONSTRAINT        => 'attachment_links_pkey';
const my $LINK_TARGET_CONSTRAINT    => 'attachment_links_target_key';
const my $VARIANT_ID_CONSTRAINT     => 'attachment_variants_pkey';
const my $VARIANT_KEY_CONSTRAINT    => 'attachment_variants_variant_key';
const my $VARIANT_OBJECT_CONSTRAINT => 'attachment_variants_object_key_key';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Service::Id;
    return GPForum::Service::Id->new;
};
has recorder => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
has schema => undef;
has record => sub { return GPForum::Service::Attachment::Record->new; };
has download_access => sub {
    my ($self) = @_;

    return GPForum::Service::Attachment::DownloadAccess->new(
        record => $self->record, );
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

sub create_intent {
    my ( $self, $intent ) = @_;

    my $result = $self->schema->txn_do(
        sub {
            return $self->_persist_intent($intent);
        }
    );

    return _intent_result($result);
}

sub _persist_intent {
    my ( $self, $intent ) = @_;

    my $existing = $self->_existing_intent($intent);
    if ($existing) {
        return $self->_existing_or_reissue( $existing, $intent );
    }

    return $self->_insert_or_reuse_intent($intent);
}

sub _existing_or_reissue {
    my ( $self, $existing, $intent ) = @_;

    if ( $self->_same_object_key( $existing, $intent ) ) {
        return $self->_finish_leftover_intent( $existing, $intent );
    }

    return $self->_insert_or_reuse_intent( $self->_reissued_intent($intent) );
}

sub _same_object_key {
    my ( $self, $existing, $intent ) = @_;

    my $stored    = $self->record->column( $existing, 'object_key' ) || q{};
    my $candidate = $intent->{object_key}                            || q{};

    return length $stored && $stored eq $candidate ? 1 : 0;
}

sub _insert_or_reuse_intent {
    my ( $self, $intent ) = @_;

    my $created = eval { return $self->_insert_intent($intent); };
    if ($created) {
        return $created;
    }

    return $self->_intent_after_conflict( $intent, $EVAL_ERROR );
}

sub _intent_after_conflict {
    my ( $self, $intent, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_intent_after_unique( $intent, $error );
}

sub _intent_after_unique {
    my ( $self, $intent, $error ) = @_;

    if ( _attachment_id_conflict($error) ) {
        return $self->_retry_or_reuse_id($intent);
    }
    if ( _object_key_conflict($error) ) {
        return $self->_reuse_object_key( $intent, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _retry_or_reuse_id {
    my ( $self, $intent ) = @_;

    my $existing = $self->_existing_intent($intent);
    if ( $self->_reusable_intent( $existing, $intent ) ) {
        return $self->_finish_leftover_intent( $existing, $intent );
    }

    return $self->_retry_attachment_id($intent);
}

sub _reusable_intent {
    my ( $self, $existing, $intent ) = @_;

    if ( !$existing ) {
        return 0;
    }

    return $self->_same_object_key( $existing, $intent );
}

sub _retry_attachment_id {
    my ( $self, $intent ) = @_;

    my $created =
      eval { return $self->_insert_intent( $self->_reissued_intent($intent) ); };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _reissued_intent {
    my ( $self, $intent ) = @_;

    my $attachment_id = $self->id_service->uuid;

    return {
        %{$intent},
        attachment_id => $attachment_id,
        object_key    => $self->_object_key_for( $intent, $attachment_id ),
    };
}

sub _object_key_for {
    my ( $self, $intent, $attachment_id ) = @_;

    return join q{/}, 'attachments', $intent->{owner_user_id}, $attachment_id;
}

sub _reuse_object_key {
    my ( $self, $intent, $error ) = @_;

    my $existing =
      $self->_single_row( 'Attachment',
        { object_key => $intent->{object_key} } );
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_finish_leftover_intent( $existing, $intent );
}

sub _attachment_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _object_key_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $KEY_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _existing_intent {
    my ( $self, $intent ) = @_;

    return $self->find_attachment( $intent->{attachment_id} );
}

sub _intent_result {
    my ($result) = @_;

    my $payload = { ok => 1, attachment => $result->{attachment} };
    if ( $result->{skipped} ) {
        $payload->{skipped} = 1;
    }

    return $payload;
}

sub link_attachment {
    my ( $self, $input ) = @_;

    my $existing = $self->_existing_link($input);
    if ($existing) {
        return $self->_idempotent_row($existing);
    }

    return $self->_insert_or_reuse_link($input);
}

sub _insert_or_reuse_link {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_create_link($input); };
    if ($created) {
        return $created;
    }

    return $self->_link_after_conflict( $input, $EVAL_ERROR );
}

sub _link_after_conflict {
    my ( $self, $input, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_link_after_unique( $input, $error );
}

sub _link_after_unique {
    my ( $self, $input, $error ) = @_;

    if ( _link_id_conflict($error) ) {
        return $self->_link_after_id_conflict($input);
    }
    if ( _link_target_conflict($error) ) {
        return $self->_reuse_link( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _link_after_id_conflict {
    my ( $self, $input ) = @_;

    my $existing = $self->_existing_link($input);
    if ($existing) {
        return $self->_idempotent_row($existing);
    }

    return $self->_retry_link_id($input);
}

sub _retry_link_id {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_create_link($input); };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _reuse_link {
    my ( $self, $input, $error ) = @_;

    my $existing = $self->_existing_link($input);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_idempotent_row($existing);
}

sub _link_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $LINK_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _link_target_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $LINK_TARGET_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _create_link {
    my ( $self, $input ) = @_;

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

sub mark_uploaded {
    my ( $self, $attachment_id ) = @_;

    my $attachment = $self->find_attachment($attachment_id);
    if ( !$attachment ) {
        return;
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

sub record_scan {
    my ( $self, $input ) = @_;

    my $existing = $self->find_attachment( $input->{attachment_id} );
    if ( !$existing ) {
        return;
    }

    my $replayed = $self->lifecycle->replayed_scan( $existing, $input );
    if ($replayed) {
        return $replayed;
    }

    my $updated = $self->_update_attachment( $input->{attachment_id},
        $self->lifecycle->scan_changes($input) );
    $self->_record_scan_event($input);

    return $updated;
}

sub terminal_scan {
    my ( $self, $attachment ) = @_;

    if ( !$self->lifecycle->already_scanned($attachment) ) {
        return;
    }

    return $self->lifecycle->scanned_replay($attachment);
}

sub find_variant {
    my ( $self, $input ) = @_;

    return $self->_existing_variant($input);
}

sub add_variant {
    my ( $self, $input ) = @_;

    my $existing = $self->find_variant($input);
    if ($existing) {
        return $self->_idempotent_row($existing);
    }

    return $self->_insert_or_reuse_variant($input);
}

sub _insert_or_reuse_variant {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_create_variant($input); };
    if ($created) {
        return $created;
    }

    return $self->_variant_after_conflict( $input, $EVAL_ERROR );
}

sub _variant_after_conflict {
    my ( $self, $input, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_variant_after_unique( $input, $error );
}

sub _variant_after_unique {
    my ( $self, $input, $error ) = @_;

    if ( _variant_id_conflict($error) ) {
        return $self->_variant_after_id_conflict($input);
    }
    if ( _variant_reuse_conflict($error) ) {
        return $self->_reuse_variant( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _variant_after_id_conflict {
    my ( $self, $input ) = @_;

    my $existing = $self->find_variant($input);
    if ($existing) {
        return $self->_idempotent_row($existing);
    }

    return $self->_retry_variant_id($input);
}

sub _retry_variant_id {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_create_variant($input); };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _reuse_variant {
    my ( $self, $input, $error ) = @_;

    my $existing = $self->find_variant($input);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_idempotent_row($existing);
}

sub _variant_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $VARIANT_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _variant_reuse_conflict {
    my ($error) = @_;

    if ( _variant_key_conflict($error) ) {
        return 1;
    }

    return _variant_object_conflict($error);
}

sub _variant_key_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $VARIANT_KEY_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _variant_object_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $VARIANT_OBJECT_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _create_variant {
    my ( $self, $input ) = @_;

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

sub _idempotent_row {
    my ( $self, $existing ) = @_;

    return { %{ $self->record->row_hash($existing) }, idempotent => 1 };
}

sub find_attachment {
    my ( $self, $attachment_id ) = @_;

    return $self->schema->resultset('Attachment')->find($attachment_id);
}

sub download_for {
    my ( $self, $input ) = @_;

    my $attachment = $self->find_attachment( $input->{attachment_id} );
    my $denied     = $self->download_access->unavailable($attachment);
    if ($denied) {
        return $denied;
    }

    return $self->_authorized_download( $attachment, $input->{viewer_user_id} );
}

sub attachments_for_posts {
    my ( $self, $post_ids, $input ) = @_;

    my %requested = map { $_ => 1 } @{$post_ids};
    my %by_post;
    for my $link ( $self->_post_links( [ keys %requested ] ) ) {
        $self->_append_post_attachment(
            {
                by_post        => \%by_post,
                link           => $link,
                requested      => \%requested,
                viewer_user_id => $input->{viewer_user_id},
            }
        );
    }

    return \%by_post;
}

sub cleanup_orphans {
    my ( $self, $input ) = @_;

    my @deleted;
    for my $attachment ( $self->_orphan_candidates($input) ) {
        my $row = $self->_delete_orphan( $attachment, $input );
        if ($row) {
            push @deleted, $row;
        }
    }

    return $self->lifecycle->cleanup_result( \@deleted );
}

sub delete_linked {
    my ( $self, $input ) = @_;

    if ( !$self->_existing_link($input) ) {
        return { error => 'not_found', ok => 0 };
    }

    return $self->soft_delete(
        $input->{attachment_id},
        $input->{actor_id}, $self->lifecycle->author_delete_reason($input),
    );
}

sub soft_delete {
    my ( $self, $attachment_id, $actor_id, $reason ) = @_;

    my $work = sub {
        return $self->_soft_delete_once( $attachment_id, $actor_id, $reason );
    };

    return $self->schema->can('txn_do')
      ? $self->schema->txn_do($work)
      : $work->();
}

sub _soft_delete_once {
    my ( $self, $attachment_id, $actor_id, $reason ) = @_;

    my $attachment = $self->find_attachment($attachment_id);
    if ( !$attachment ) {
        return { error => 'not_found', ok => 0 };
    }
    if ( $self->lifecycle->already_deleted($attachment) ) {
        return $self->lifecycle->deleted_replay($attachment);
    }

    return $self->_delete_attachment( $attachment, $actor_id, $reason );
}

sub _existing_link {
    my ( $self, $input ) = @_;

    return $self->_single_row(
        'AttachmentLink',
        {
            attachment_id => $input->{attachment_id},
            target_id     => $input->{target_id},
            target_type   => $input->{target_type},
        }
    );
}

sub _existing_variant {
    my ( $self, $input ) = @_;

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

sub _variant_by_object_key {
    my ( $self, $input ) = @_;

    my $object_key = $input->{object_key};
    if ( !defined $object_key || !length $object_key ) {
        return;
    }

    return $self->_single_row(
        'AttachmentVariant',
        {
            object_key => $object_key,
        }
    );
}

sub _authorized_download {
    my ( $self, $attachment, $viewer_user_id ) = @_;

    return $self->download_access->authorized(
        {
            attachment     => $attachment,
            linked         => $self->_linked_targets($attachment),
            viewer_user_id => $viewer_user_id,
        }
    );
}

sub _linked_targets {
    my ( $self, $attachment ) = @_;

    return [
        map { $self->_linked_target($_) } $self->_attachment_links(
            $self->record->column( $attachment, 'attachment_id' )
        )
    ];
}

sub _linked_target {
    my ( $self, $link ) = @_;

    return {
        link   => $link,
        target => $self->_target_row(
            $self->record->column( $link, 'target_type' ),
            $self->record->column( $link, 'target_id' ),
        ),
    };
}

sub _post_links {
    my ( $self, $post_ids ) = @_;

    my $search = $self->schema->resultset('AttachmentLink')->search(
        {
            target_id   => { -in => $post_ids },
            target_type => $self->lifecycle->post_link_target,
        },
        { rows => $self->lifecycle->post_link_rows($post_ids) },
    );

    return $self->record->rows($search);
}

sub _append_post_attachment {
    my ( $self, $input ) = @_;

    my $post_id = $self->record->column( $input->{link}, 'target_id' );
    if ( !$input->{requested}{$post_id} ) {
        return;
    }

    return $self->_push_visible_attachment( $input, $post_id );
}

sub _push_visible_attachment {
    my ( $self, $input, $post_id ) = @_;

    my $decision = $self->download_for(
        {
            attachment_id =>
              $self->record->column( $input->{link}, 'attachment_id' ),
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

sub _orphan_candidates {
    my ( $self, $input ) = @_;

    my $search = $self->schema->resultset('Attachment')->search(
        $self->lifecycle->orphan_where,
        $self->lifecycle->orphan_search_attrs($input),
    );

    return $self->record->rows($search);
}

sub _delete_orphan {
    my ( $self, $attachment, $input ) = @_;

    if ( $self->_attachment_has_links($attachment) ) {
        return;
    }

    my $deleted = $self->soft_delete(
        $self->record->column( $attachment, 'attachment_id' ),
        $self->lifecycle->orphan_actor( $attachment, $input ),
        $self->lifecycle->orphan_reason($input),
    );
    if ( $deleted->{ok} ) {
        return $deleted->{attachment};
    }

    return;
}

sub _delete_attachment {
    my ( $self, $attachment, $actor_id, $reason ) = @_;

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

sub _record_deletion {
    my ( $self, $input ) = @_;

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

sub _insert_intent {
    my ( $self, $intent ) = @_;

    my $attachment = $self->schema->resultset('Attachment')->create($intent);
    $self->_write_intent_event($intent);

    return { attachment => $attachment };
}

sub _finish_leftover_intent {
    my ( $self, $existing, $intent ) = @_;

    $self->_ensure_intent_write( $existing, $intent );

    return { attachment => $existing, skipped => 1 };
}

sub _ensure_intent_write {
    my ( $self, $existing, $intent ) = @_;

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

sub _intent_event_exists {
    my ( $self, $existing ) = @_;

    return $self->_single_row(
        'EventLog',
        {
            idempotency_key => join( q{:},
                'attachment.uploaded',
                $self->record->column( $existing, 'attachment_id' ) ),
        }
    );
}

sub _write_intent_event {
    my ( $self, $intent ) = @_;

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

sub _record_scan_event {
    my ( $self, $input ) = @_;

    my $correlation_id = $self->id_service->uuid;
    $self->_record_event(
        $self->events->envelope(
            {
                actor_id       => $input->{actor_id},
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

sub _update_attachment {
    my ( $self, $attachment_id, $changes ) = @_;

    my $attachment = $self->find_attachment($attachment_id);
    if ( !$attachment ) {
        return;
    }

    $attachment->update($changes);

    return {
        attachment_id => $attachment_id,
        %{$changes},
    };
}

sub _attachment_links {
    my ( $self, $attachment_id ) = @_;

    my $search = $self->schema->resultset('AttachmentLink')->search(
        { attachment_id => $attachment_id },
        { rows          => $self->lifecycle->link_lookup_rows },
    );

    return $self->record->rows($search);
}

sub _attachment_has_links {
    my ( $self, $attachment ) = @_;

    my @links = $self->_attachment_links(
        $self->record->column( $attachment, 'attachment_id' ) );

    return @links ? 1 : 0;
}

sub _target_row {
    my ( $self, $target_type, $target_id ) = @_;

    my %resultset_for = (
        post   => 'Post',
        thread => 'Thread',
    );
    if ( !exists $resultset_for{$target_type} ) {
        return;
    }

    my $resultset =
      eval { return $self->schema->resultset( $resultset_for{$target_type} ); };
    if ( !$resultset ) {
        return;
    }

    return $resultset->find($target_id);
}

sub _single_row {
    my ( $self, $resultset_name, $query ) = @_;

    my $search =
      $self->schema->resultset($resultset_name)
      ->search( $query, { rows => 1 } );
    if ( $search->can('single') ) {
        return $search->single;
    }

    my @rows = $self->record->rows($search);
    return $rows[0];
}

sub _record_event {
    my ( $self, $event ) = @_;

    $self->recorder->record_event( %{$event} );

    return;
}

sub _record_audit {
    my ( $self, $action, $intent, $correlation_id ) = @_;

    $self->recorder->record_audit(
        %{ $self->events->audit( $action, $intent, $correlation_id ) } );

    return;
}

1;
