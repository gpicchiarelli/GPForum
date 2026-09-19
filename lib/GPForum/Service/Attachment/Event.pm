package GPForum::Service::Attachment::Event;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $AGGREGATE_TYPE => 'attachment';
const my $SCHEMA_VERSION => 1;
const my $SCAN_CLEAN     => 'clean';
const my $SCANNED_TYPE   => 'attachment.scanned';
const my $QUARANTINED    => 'attachment.quarantined';

has id_service => sub {
    require GPForum::Service::Id;
    return GPForum::Service::Id->new;
};

sub envelope {
    my ( $self, $input ) = @_;

    return {
        actor_id          => $input->{actor_id},
        aggregate_id      => $input->{attachment_id},
        aggregate_type    => $AGGREGATE_TYPE,
        aggregate_version => $SCHEMA_VERSION,
        causation_id      => undef,
        correlation_id    => $input->{correlation_id},
        event_id          => $self->id_service->uuid,
        event_type        => $input->{event_type},
        idempotency_key   =>
          join( q{:}, $input->{event_type}, $input->{attachment_id} ),
        metadata       => {},
        payload        => $input->{payload},
        schema_version => $SCHEMA_VERSION,
    };
}

sub scan_event_type {
    my ( undef, $scan_status ) = @_;

    if ( $scan_status eq $SCAN_CLEAN ) {
        return $SCANNED_TYPE;
    }

    return $QUARANTINED;
}

sub uploaded_payload {
    my ( undef, $intent ) = @_;

    return {
        attachment_id => $intent->{attachment_id},
        byte_size     => $intent->{byte_size},
        media_type    => $intent->{media_type},
        object_key    => $intent->{object_key},
        owner_user_id => $intent->{owner_user_id},
    };
}

sub scan_payload {
    my ( undef, $input ) = @_;

    return {
        attachment_id => $input->{attachment_id},
        reason        => $input->{reason},
        scan_status   => $input->{scan_status},
    };
}

sub deleted_payload {
    my ( undef, $input ) = @_;

    return {
        attachment_id => $input->{attachment_id},
        reason        => $input->{reason},
    };
}

sub audit {
    my ( undef, $action, $intent, $correlation_id ) = @_;

    return {
        action         => $action,
        actor_id       => $intent->{owner_user_id},
        correlation_id => $correlation_id,
        metadata       => { object_key => $intent->{object_key} },
        schema_version => $SCHEMA_VERSION,
        target_id      => $intent->{attachment_id},
        target_type    => $AGGREGATE_TYPE,
    };
}

1;

__END__

=head1 NAME

GPForum::Service::Attachment::Event - Attachment event envelopes and audit hashes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $event = $events->envelope(
        {
            actor_id       => $actor_id,
            attachment_id  => $attachment_id,
            correlation_id => $correlation_id,
            event_type     => 'attachment.uploaded',
            payload        => $events->uploaded_payload($intent),
        }
    );

=head1 DESCRIPTION

Owns attachment EventLog envelopes, scan event types, payload hashes, and
AuditLog argument hashes. It does not persist rows.
L<GPForum::Service::Attachment::Store> still writes EventLog, OutboxMessage,
and AuditLog.

=head1 SUBROUTINES/METHODS

=head2 envelope

Returns the EventLog hash for an attachment event.

=head2 scan_event_type

Returns C<attachment.scanned> for a clean scan, otherwise
C<attachment.quarantined>.

=head2 uploaded_payload

Returns the uploaded-intent payload.

=head2 scan_payload

Returns the scan payload.

=head2 deleted_payload

Returns the delete payload.

=head2 audit

Returns the AuditLog argument hash.

=head1 DIAGNOSTICS

None. Persistence errors stay in the store.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>. C<GPForum::Service::Id> is required
lazily unless an C<id_service> is injected.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Orphan cleanup and resultset writes stay on the store.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
