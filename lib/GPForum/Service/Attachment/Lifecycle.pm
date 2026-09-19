package GPForum::Service::Attachment::Lifecycle;

use strict;
use warnings;

use Const::Fast;
use GPForum::Service::Attachment::Record;
use GPForum::Service::Clock;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $STATE_AVAILABLE   => 'available';
const my $STATE_DELETED     => 'deleted';
const my $STATE_INTENT      => 'intent';
const my $STATE_QUARANTINED => 'quarantined';
const my $SCAN_CLEAN        => 'clean';
const my $ORPHAN_LIMIT      => 100;
const my $ORPHAN_REASON     => 'orphan cleanup';
const my $LINKS_PER_POST    => 10;
const my $LINK_LOOKUP_ROWS  => 10;
const my $TARGET_POST       => 'post';

has clock  => sub { return GPForum::Service::Clock->new; };
has record => sub { return GPForum::Service::Attachment::Record->new; };

sub already_uploaded {
    my ( $self, $attachment ) = @_;

    my $state = $self->record->column( $attachment, 'state' ) || q{};
    return $state ne $STATE_INTENT ? 1 : 0;
}

sub uploaded_replay {
    my ( $self, $attachment ) = @_;

    return {
        attachment_id => $self->record->column( $attachment, 'attachment_id' ),
        idempotent    => 1,
        state         => $self->record->column( $attachment, 'state' ),
        uploaded_at   => $self->record->column( $attachment, 'uploaded_at' ),
    };
}

sub scan_state {
    my ( undef, $input ) = @_;

    if ( $input->{scan_status} eq $SCAN_CLEAN ) {
        return $STATE_AVAILABLE;
    }

    return $STATE_QUARANTINED;
}

sub replayed_scan {
    my ( $self, $existing, $input ) = @_;

    if ( !$self->scan_matches( $existing, $input ) ) {
        return;
    }

    return {
        attachment_id => $input->{attachment_id},
        idempotent    => 1,
        scan_status   => $self->record->column( $existing, 'scan_status' ),
        state         => $self->record->column( $existing, 'state' ),
    };
}

sub scan_matches {
    my ( $self, $existing, $input ) = @_;

    my $scan  = $self->record->column( $existing, 'scan_status' ) || q{};
    my $state = $self->record->column( $existing, 'state' )       || q{};
    if ( $scan ne $input->{scan_status} ) {
        return 0;
    }

    return $state eq $self->scan_state($input) ? 1 : 0;
}

sub scan_changes {
    my ( $self, $input ) = @_;

    my $state   = $self->scan_state($input);
    my $changes = {
        scanned_at  => $self->clock->now_iso8601,
        scan_status => $input->{scan_status},
        state       => $state,
    };
    if ( $state eq $STATE_QUARANTINED ) {
        $changes->{quarantined_at} = $self->clock->now_iso8601;
    }

    return $changes;
}

sub already_deleted {
    my ( $self, $attachment ) = @_;

    my $state = $self->record->column( $attachment, 'state' ) || q{};
    return $state eq $STATE_DELETED ? 1 : 0;
}

sub deleted_replay {
    my ( $self, $attachment ) = @_;

    return {
        attachment => $self->record->row_hash($attachment),
        idempotent => 1,
        ok         => 1,
    };
}

sub orphan_limit {
    my ( undef, $input ) = @_;

    if ( exists $input->{limit} && $input->{limit} ) {
        return $input->{limit};
    }

    return $ORPHAN_LIMIT;
}

sub orphan_reason {
    my ( undef, $input ) = @_;

    if (   exists $input->{reason}
        && defined $input->{reason}
        && length $input->{reason} )
    {
        return $input->{reason};
    }

    return $ORPHAN_REASON;
}

sub orphan_actor {
    my ( $self, $attachment, $input ) = @_;

    if (   exists $input->{actor_id}
        && defined $input->{actor_id}
        && length $input->{actor_id} )
    {
        return $input->{actor_id};
    }

    return $self->record->column( $attachment, 'owner_user_id' );
}

sub orphan_where {
    return { state => $STATE_INTENT };
}

sub orphan_search_attrs {
    my ( $self, $input ) = @_;

    return {
        order_by => [ { -asc => 'created_at' } ],
        rows     => $self->orphan_limit($input),
    };
}

sub cleanup_result {
    my ( undef, $deleted ) = @_;

    return {
        deleted => $deleted,
        ok      => 1,
    };
}

sub links_per_post {
    return $LINKS_PER_POST;
}

sub post_link_target {
    return $TARGET_POST;
}

sub post_link_rows {
    my ( undef, $post_ids ) = @_;

    return scalar @{$post_ids} * $LINKS_PER_POST;
}

sub link_lookup_rows {
    return $LINK_LOOKUP_ROWS;
}

1;

__END__

=head1 NAME

GPForum::Service::Attachment::Lifecycle - Upload, scan, delete, and orphan states.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $state = $lifecycle->scan_state( { scan_status => 'clean' } );

=head1 DESCRIPTION

Owns upload replay, scan state transitions, delete replay hashes, orphan
cleanup search/actor/reason policy, and per-post link fetch caps. It does
not write rows.
L<GPForum::Service::Attachment::Store> still updates attachments, deletes
orphans, and records events.

=head1 SUBROUTINES/METHODS

=head2 already_uploaded

True when the attachment has left the intent state.

=head2 uploaded_replay

Returns the idempotent upload hash.

=head2 scan_state

Returns C<available> for a clean scan, otherwise C<quarantined>.

=head2 replayed_scan

Returns the idempotent scan hash when status and state already match.

=head2 scan_matches

True when stored scan status and derived state match the input.

=head2 scan_changes

Returns the scan update columns, including C<quarantined_at> when needed.

=head2 already_deleted

True when the attachment is already deleted.

=head2 deleted_replay

Returns the idempotent delete hash.

=head2 orphan_limit

Returns the candidate row cap, defaulting to 100.

=head2 orphan_reason

Returns the delete reason, defaulting to C<orphan cleanup>.

=head2 orphan_actor

Returns the supplied actor id, otherwise the attachment owner.

=head2 orphan_where

Returns the intent-state search clause for orphan candidates.

=head2 orphan_search_attrs

Returns oldest-first search attributes including the row cap.

=head2 cleanup_result

Returns the normalized orphan cleanup hash.

=head2 links_per_post

Returns the per-post attachment-link cap of 10.

=head2 post_link_target

Returns the C<post> target type for link listing.

=head2 post_link_rows

Returns the search row cap for a list of post ids.

=head2 link_lookup_rows

Returns the per-attachment link lookup cap of 10.

=head1 DIAGNOSTICS

None. Persistence errors stay in the store.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<GPForum::Service::Attachment::Record>,
L<GPForum::Service::Clock>, and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The store still loads candidates and performs deletes. Event and audit
hashes live in L<GPForum::Service::Attachment::Event>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
