package GPForum::Service::Attachment::Store;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $AGGREGATE_TYPE    => 'attachment';
const my $SCHEMA_VERSION    => 1;
const my $STATE_AVAILABLE   => 'available';
const my $STATE_DELETED     => 'deleted';
const my $STATE_UPLOADED    => 'uploaded';
const my $STATE_QUARANTINED => 'quarantined';
const my $SCAN_CLEAN        => 'clean';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has recorder   => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
has schema => undef;

sub create_intent {
    my ( $self, $intent ) = @_;

    my $result = $self->schema->txn_do(
        sub {
            return $self->_insert_intent($intent);
        }
    );

    return { ok => 1, attachment => $result->{attachment} };
}

sub link_attachment {
    my ( $self, $input ) = @_;

    my $existing = $self->_single_row(
        'AttachmentLink',
        {
            attachment_id => $input->{attachment_id},
            target_id     => $input->{target_id},
            target_type   => $input->{target_type},
        }
    );
    return { %{ _row_hash($existing) }, idempotent => 1 } if $existing;

    my $row = {
        attachment_link_id => $self->id_service->uuid,
        attachment_id      => $input->{attachment_id},
        target_type        => $input->{target_type},
        target_id          => $input->{target_id},
        created_at         => $self->clock->now_iso8601,
    };

    $self->schema->resultset('AttachmentLink')->create($row);

    return $row;
}

sub mark_uploaded {
    my ( $self, $attachment_id ) = @_;

    my $attachment = $self->find_attachment($attachment_id);
    return if !$attachment;
    return {
        attachment_id => $attachment_id,
        idempotent    => 1,
        state         => _column( $attachment, 'state' ),
        uploaded_at   => _column( $attachment, 'uploaded_at' ),
      }
      if ( _column( $attachment, 'state' ) || q{} ) ne 'intent';

    return $self->_update_attachment(
        $attachment_id,
        {
            state       => 'uploaded',
            uploaded_at => $self->clock->now_iso8601,
        }
    );
}

sub record_scan {
    my ( $self, $input ) = @_;

    my $state =
        $input->{scan_status} eq $SCAN_CLEAN
      ? $STATE_AVAILABLE
      : $STATE_QUARANTINED;
    my $existing = $self->find_attachment( $input->{attachment_id} );
    return if !$existing;
    return {
        attachment_id => $input->{attachment_id},
        idempotent    => 1,
        scan_status   => _column( $existing, 'scan_status' ),
        state         => _column( $existing, 'state' ),
      }
      if ( _column( $existing, 'scan_status' ) || q{} ) eq $input->{scan_status}
      && ( _column( $existing, 'state' ) || q{} ) eq $state;

    my $changes = {
        state       => $state,
        scan_status => $input->{scan_status},
        scanned_at  => $self->clock->now_iso8601,
    };
    if ( $state eq $STATE_QUARANTINED ) {
        $changes->{quarantined_at} = $self->clock->now_iso8601;
    }

    my $updated =
      $self->_update_attachment( $input->{attachment_id}, $changes );
    $self->_record_scan_event($input);

    return $updated;
}

sub add_variant {
    my ( $self, $input ) = @_;

    my $existing = $self->_single_row(
        'AttachmentVariant',
        {
            attachment_id => $input->{attachment_id},
            variant_type  => $input->{variant_type},
        }
    );
    return { %{ _row_hash($existing) }, idempotent => 1 } if $existing;

    my $row = {
        attachment_variant_id => $self->id_service->uuid,
        attachment_id         => $input->{attachment_id},
        variant_type          => $input->{variant_type},
        object_key            => $input->{object_key},
        media_type            => $input->{media_type},
        byte_size             => $input->{byte_size},
        created_at            => $self->clock->now_iso8601,
    };

    $self->schema->resultset('AttachmentVariant')->create($row);

    return $row;
}

sub find_attachment {
    my ( $self, $attachment_id ) = @_;

    return $self->schema->resultset('Attachment')->find($attachment_id);
}

sub download_for {
    my ( $self, $input ) = @_;

    my $attachment = $self->find_attachment( $input->{attachment_id} );
    return { ok => 0, error => 'not_found' } if !$attachment;
    return { ok => 0, error => 'not_found' }
      if !_attachment_is_downloadable($attachment);

    my $viewer_user_id = $input->{viewer_user_id};
    my @links          = $self->_attachment_links( $input->{attachment_id} );
    return _download_payload($attachment)
      if !@links && _is_owner( $attachment, $viewer_user_id );

    for my $link (@links) {
        return _download_payload($attachment)
          if $self->_link_allows_download( $link, $attachment,
            $viewer_user_id );
    }

    return { ok => 0, error => 'forbidden' };
}

sub attachments_for_posts {
    my ( $self, $post_ids, $input ) = @_;

    my %requested = map { $_ => 1 } @{$post_ids};
    my $search    = $self->schema->resultset('AttachmentLink')->search(
        {
            target_type => 'post',
            target_id   => { -in => [ keys %requested ] },
        },
        {
            rows => scalar( keys %requested ) * 10,
        }
    );
    my %by_post;
    for my $link ( _rows($search) ) {
        my $post_id = _column( $link, 'target_id' );
        next if !$requested{$post_id};

        my $decision = $self->download_for(
            {
                attachment_id  => _column( $link, 'attachment_id' ),
                viewer_user_id => $input->{viewer_user_id},
            }
        );
        next if !$decision->{ok};

        push @{ $by_post{$post_id} },
          _attachment_view( $decision->{attachment} );
    }

    return \%by_post;
}

sub cleanup_orphans {
    my ( $self, $input ) = @_;

    my $limit  = $input->{limit} || 100;
    my $query  = { state => 'intent' };
    my $search = $self->schema->resultset('Attachment')->search(
        $query,
        {
            order_by => [ { -asc => 'created_at' } ],
            rows     => $limit,
        }
    );
    my @deleted;
    for my $attachment ( _rows($search) ) {
        next if $self->_attachment_has_links($attachment);

        my $deleted = $self->soft_delete(
            _column( $attachment, 'attachment_id' ),
            $input->{actor_id} || _column( $attachment, 'owner_user_id' ),
            $input->{reason}   || 'orphan cleanup',
        );
        push @deleted, $deleted->{attachment} if $deleted->{ok};
    }

    return { ok => 1, deleted => \@deleted };
}

sub soft_delete {
    my ( $self, $attachment_id, $actor_id, $reason ) = @_;

    my $attachment = $self->find_attachment($attachment_id);
    return { ok => 0, error => 'not_found' } if !$attachment;
    return {
        ok         => 1,
        attachment => _row_hash($attachment),
        idempotent => 1,
      }
      if ( _column( $attachment, 'state' ) || q{} ) eq $STATE_DELETED;

    my $timestamp = $self->clock->now_iso8601;
    $attachment->update(
        {
            deleted_at => $timestamp,
            state      => $STATE_DELETED,
        }
    );
    my $row = {
        %{ _row_hash($attachment) },
        deleted_at => $timestamp,
        state      => $STATE_DELETED,
    };
    my $correlation_id = $self->id_service->uuid;
    my $event          = $self->_event(
        {
            actor_id       => $actor_id,
            attachment_id  => $attachment_id,
            correlation_id => $correlation_id,
            event_type     => 'attachment.deleted',
            payload        => {
                attachment_id => $attachment_id,
                reason        => $reason,
            },
        }
    );
    $self->_record_event($event);
    $self->_record_audit(
        'attachment.deleted',
        {
            %{$row},
            owner_user_id => $actor_id,
            reason        => $reason,
        },
        $correlation_id
    );

    return { ok => 1, attachment => $row };
}

sub _insert_intent {
    my ( $self, $intent ) = @_;

    my $attachment = $self->schema->resultset('Attachment')->create($intent);
    my $correlation_id = $self->id_service->uuid;
    my $event          = $self->_event(
        {
            event_type     => 'attachment.uploaded',
            attachment_id  => $intent->{attachment_id},
            actor_id       => $intent->{owner_user_id},
            correlation_id => $correlation_id,
            payload        => {
                attachment_id => $intent->{attachment_id},
                owner_user_id => $intent->{owner_user_id},
                object_key    => $intent->{object_key},
                media_type    => $intent->{media_type},
                byte_size     => $intent->{byte_size},
            },
        }
    );

    $self->_record_event($event);
    $self->_record_audit( 'attachment.uploaded', $intent, $correlation_id );

    return { attachment => $attachment };
}

sub _record_scan_event {
    my ( $self, $input ) = @_;

    my $event_type =
      $input->{scan_status} eq 'clean'
      ? 'attachment.scanned'
      : 'attachment.quarantined';
    my $correlation_id = $self->id_service->uuid;
    my $event          = $self->_event(
        {
            event_type     => $event_type,
            attachment_id  => $input->{attachment_id},
            actor_id       => $input->{actor_id},
            correlation_id => $correlation_id,
            payload        => {
                attachment_id => $input->{attachment_id},
                scan_status   => $input->{scan_status},
                reason        => $input->{reason},
            },
        }
    );

    $self->_record_event($event);

    return;
}

sub _update_attachment {
    my ( $self, $attachment_id, $changes ) = @_;

    my $attachment = $self->find_attachment($attachment_id);
    return if !$attachment;

    $attachment->update($changes);

    return {
        attachment_id => $attachment_id,
        %{$changes},
    };
}

sub _attachment_links {
    my ( $self, $attachment_id ) = @_;

    my $search = $self->schema->resultset('AttachmentLink')
      ->search( { attachment_id => $attachment_id }, { rows => 10 } );

    return _rows($search);
}

sub _attachment_has_links {
    my ( $self, $attachment ) = @_;

    my $attachment_id = _column( $attachment, 'attachment_id' );
    my @links         = $self->_attachment_links($attachment_id);

    return @links ? 1 : 0;
}

sub _link_allows_download {
    my ( $self, $link, $attachment, $viewer_user_id ) = @_;

    my $target_type = _column( $link, 'target_type' );
    return _is_owner( $attachment, $viewer_user_id )
      if $target_type eq 'profile';

    my $target =
      $self->_target_row( $target_type, _column( $link, 'target_id' ) );
    return if !_target_is_visible( $target, $target_type );
    return _visibility_allows( $target, $attachment, $viewer_user_id );
}

sub _target_row {
    my ( $self, $target_type, $target_id ) = @_;

    my %resultset_for = (
        post   => 'Post',
        thread => 'Thread',
    );
    return if !exists $resultset_for{$target_type};

    my $resultset =
      eval { $self->schema->resultset( $resultset_for{$target_type} ) };
    return if !$resultset;

    return $resultset->find($target_id);
}

sub _target_is_visible {
    my ( $target, $target_type ) = @_;

    return if !$target;
    return if defined _column( $target, 'deleted_at' );
    return if defined _column( $target, 'hidden_at' );

    my $state = _column( $target, 'moderation_state' ) || q{};
    return $state eq 'visible'
      || ( $target_type eq 'thread' && $state eq 'locked' )
      ? 1
      : 0;
}

sub _visibility_allows {
    my ( $target, $attachment, $viewer_user_id ) = @_;

    my $visibility = _column( $target, 'visibility' ) || 'public';
    return 1 if $visibility eq 'public';
    return 1 if $visibility eq 'members' && _has_text($viewer_user_id);
    return 1
      if $visibility eq 'private'
      && ( _column( $target, 'author_user_id' ) || q{} ) eq
      ( $viewer_user_id || q{} );
    return 1 if _is_owner( $attachment, $viewer_user_id );

    return;
}

sub _attachment_is_downloadable {
    my ($attachment) = @_;

    return if defined _column( $attachment, 'deleted_at' );
    return if ( _column( $attachment, 'state' ) || q{} ) ne $STATE_AVAILABLE;
    return if ( _column( $attachment, 'scan_status' ) || q{} ) ne $SCAN_CLEAN;

    return 1;
}

sub _download_payload {
    my ($attachment) = @_;

    return {
        ok                => 1,
        attachment        => _row_hash($attachment),
        attachment_id     => _column( $attachment, 'attachment_id' ),
        byte_size         => _column( $attachment, 'byte_size' ),
        media_type        => _column( $attachment, 'media_type' ),
        object_key        => _column( $attachment, 'object_key' ),
        original_filename => _column( $attachment, 'original_filename' ),
    };
}

sub _attachment_view {
    my ($attachment) = @_;

    return {
        attachment_id     => _column( $attachment, 'attachment_id' ),
        byte_size         => _column( $attachment, 'byte_size' ),
        media_type        => _column( $attachment, 'media_type' ),
        original_filename => _column( $attachment, 'original_filename' ),
    };
}

sub _is_owner {
    my ( $attachment, $viewer_user_id ) = @_;

    return if !_has_text($viewer_user_id);

    return ( _column( $attachment, 'owner_user_id' ) || q{} ) eq $viewer_user_id
      ? 1
      : 0;
}

sub _single_row {
    my ( $self, $resultset_name, $query ) = @_;

    my $search =
      $self->schema->resultset($resultset_name)
      ->search( $query, { rows => 1 } );
    return $search->single if $search->can('single');

    my @rows = _rows($search);
    return $rows[0];
}

sub _row_hash {
    my ($row) = @_;

    return {}                  if !$row;
    return { %{$row} }         if ref $row eq 'HASH';
    return { %{ $row->data } } if $row->can('data');

    return {};
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search && $search->can('all');
    return @{ $search->rows } if $search && $search->can('rows');

    return;
}

sub _column {
    my ( $row, $name ) = @_;

    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row && $row->can('get_column');

    return;
}

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value ? 1 : 0;
}

sub _record_event {
    my ( $self, $event ) = @_;

    $self->recorder->record_event( %{$event} );

    return;
}

sub _record_audit {
    my ( $self, $action, $intent, $correlation_id ) = @_;

    $self->recorder->record_audit(
        action         => $action,
        schema_version => $SCHEMA_VERSION,
        actor_id       => $intent->{owner_user_id},
        target_type    => $AGGREGATE_TYPE,
        target_id      => $intent->{attachment_id},
        correlation_id => $correlation_id,
        metadata       => { object_key => $intent->{object_key} },
    );

    return;
}

sub _event {
    my ( $self, $input ) = @_;

    return {
        event_id          => $self->id_service->uuid,
        event_type        => $input->{event_type},
        schema_version    => $SCHEMA_VERSION,
        aggregate_type    => $AGGREGATE_TYPE,
        aggregate_id      => $input->{attachment_id},
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $input->{actor_id},
        correlation_id    => $input->{correlation_id},
        causation_id      => undef,
        idempotency_key   =>
          join( q{:}, $input->{event_type}, $input->{attachment_id} ),
        payload  => $input->{payload},
        metadata => {},
    };
}

1;
