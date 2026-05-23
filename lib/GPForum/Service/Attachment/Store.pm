package GPForum::Service::Attachment::Store;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;
use GPForum::Service::Outbox::MessageBuilder;

our $VERSION = '0.001';

const my $AGGREGATE_TYPE => 'attachment';
const my $SCHEMA_VERSION => 1;

has clock          => sub { return GPForum::Service::Clock->new; };
has id_service     => sub { return GPForum::Service::Id->new; };
has outbox_builder => sub {
    my ($self) = @_;

    return GPForum::Service::Outbox::MessageBuilder->new(
        id_service => $self->id_service, );
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

    my $state = $input->{scan_status} eq 'clean' ? 'available' : 'quarantined';
    my $changes = {
        state       => $state,
        scan_status => $input->{scan_status},
        scanned_at  => $self->clock->now_iso8601,
    };
    if ( $state eq 'quarantined' ) {
        $changes->{quarantined_at} = $self->clock->now_iso8601;
    }

    my $updated =
      $self->_update_attachment( $input->{attachment_id}, $changes );
    $self->_record_scan_event($input);

    return $updated;
}

sub add_variant {
    my ( $self, $input ) = @_;

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

    my $attachment =
      $self->schema->resultset('Attachment')->find($attachment_id);
    $attachment->update($changes);

    return {
        attachment_id => $attachment_id,
        %{$changes},
    };
}

sub _record_event {
    my ( $self, $event ) = @_;

    $self->schema->resultset('EventLog')->create($event);
    $self->schema->resultset('OutboxMessage')
      ->create( $self->outbox_builder->for_event($event) );

    return;
}

sub _record_audit {
    my ( $self, $action, $intent, $correlation_id ) = @_;

    $self->schema->resultset('AuditLog')->create(
        {
            audit_id       => $self->id_service->uuid,
            action         => $action,
            schema_version => $SCHEMA_VERSION,
            actor_id       => $intent->{owner_user_id},
            target_type    => $AGGREGATE_TYPE,
            target_id      => $intent->{attachment_id},
            correlation_id => $correlation_id,
            metadata       => { object_key => $intent->{object_key} },
        }
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
