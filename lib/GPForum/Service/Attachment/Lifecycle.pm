# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Attachment::Lifecycle;

use strict;
use warnings;

use Const::Fast;
use GPForum::Service::Attachment::Record;
use GPForum::Service::Clock;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $STATE_AVAILABLE      => 'available';
const my $STATE_DELETED        => 'deleted';
const my $STATE_INTENT         => 'intent';
const my $STATE_QUARANTINED    => 'quarantined';
const my $SCAN_CLEAN           => 'clean';
const my $SCAN_INFECTED        => 'infected';
const my $ORPHAN_LIMIT         => 100;
const my $ORPHAN_REASON        => 'orphan cleanup';
const my $AUTHOR_DELETE_REASON => 'author delete';
const my $LINKS_PER_POST       => 10;
const my $LINK_LOOKUP_ROWS     => 10;
const my $TARGET_POST          => 'post';

has clock  => sub { return GPForum::Service::Clock->new; };
has record => sub { return GPForum::Service::Attachment::Record->new; };

sub already_uploaded ( $self, $attachment ) {
    my $state = $self->record->column( $attachment, 'state' ) || q{};
    return $state ne $STATE_INTENT ? 1 : 0;
}

sub uploaded_replay ( $self, $attachment ) {
    return {
        attachment_id => $self->record->column( $attachment, 'attachment_id' ),
        idempotent    => 1,
        state         => $self->record->column( $attachment, 'state' ),
        uploaded_at   => $self->record->column( $attachment, 'uploaded_at' ),
    };
}

sub scan_state ( $, $input ) {
    if ( $input->{scan_status} eq $SCAN_CLEAN ) {
        return $STATE_AVAILABLE;
    }

    return $STATE_QUARANTINED;
}

sub already_scanned ( $self, $attachment ) {
    return _terminal_scan(
        $self->record->column( $attachment, 'scan_status' ),
        $self->record->column( $attachment, 'state' ),
    );
}

sub scanned_replay ( $self, $attachment ) {
    return {
        attachment_id => $self->record->column( $attachment, 'attachment_id' ),
        idempotent    => 1,
        scan_status   => $self->record->column( $attachment, 'scan_status' ),
        state         => $self->record->column( $attachment, 'state' ),
    };
}

sub replayed_scan ( $self, $existing, $input ) {
    if ( !$self->scan_matches( $existing, $input ) ) {
        my $undefined;
        return $undefined;
    }

    return {
        attachment_id => $input->{attachment_id},
        idempotent    => 1,
        scan_status   => $self->record->column( $existing, 'scan_status' ),
        state         => $self->record->column( $existing, 'state' ),
    };
}

sub _terminal_scan ( $scan, $state ) {
    if ( _clean_available( $scan, $state ) ) {
        return 1;
    }
    if ( _infected_quarantined( $scan, $state ) ) {
        return 1;
    }

    return 0;
}

sub _clean_available ( $scan, $state ) {
    if ( !_same_text( $scan, $SCAN_CLEAN ) ) {
        return 0;
    }

    return _same_text( $state, $STATE_AVAILABLE );
}

sub _infected_quarantined ( $scan, $state ) {
    if ( !_same_text( $scan, $SCAN_INFECTED ) ) {
        return 0;
    }

    return _same_text( $state, $STATE_QUARANTINED );
}

sub _same_text ( $held, $incoming ) {
    if ( _text($held) eq $incoming ) {
        return 1;
    }

    return 0;
}

sub _text ($value) {
    if ( defined $value ) {
        return $value;
    }

    return q{};
}

sub scan_matches ( $self, $existing, $input ) {
    my $scan  = $self->record->column( $existing, 'scan_status' ) || q{};
    my $state = $self->record->column( $existing, 'state' )       || q{};
    if ( $scan ne $input->{scan_status} ) {
        return 0;
    }

    return $state eq $self->scan_state($input) ? 1 : 0;
}

# The rows a new verdict may replace. Verdicts only ever tighten: an upload
# still waiting takes any verdict, and a clean file may become infected or
# failed when a later scan -- newer signatures, the backfill of files uploaded
# before scanning -- finds something. Nothing ever becomes clean over an
# infected or failed verdict, which is what a slow 'clean' racing a fast
# 'infected' would otherwise do.
sub replaceable_verdicts ( $, $scan_status ) {
    my @clauses = ( { scan_status => 'pending', state => 'uploaded' } );
    if ( $scan_status ne $SCAN_CLEAN ) {
        push @clauses,
          { scan_status => $SCAN_CLEAN, state => $STATE_AVAILABLE };
    }

    return \@clauses;
}

sub scan_changes ( $self, $input ) {
    my $state   = $self->scan_state($input);
    my $changes = {
        scanned_at     => $self->clock->now_iso8601,
        scan_status    => $input->{scan_status},
        scan_engine    => $input->{scan_engine},
        scan_error     => undef,
        scan_signature => $input->{scan_signature},
        state          => $state,
    };
    if ( $state eq $STATE_QUARANTINED ) {
        $changes->{quarantined_at} = $self->clock->now_iso8601;
    }

    return $changes;
}

sub already_deleted ( $self, $attachment ) {
    my $state = $self->record->column( $attachment, 'state' ) || q{};
    return $state eq $STATE_DELETED ? 1 : 0;
}

sub deleted_replay ( $self, $attachment ) {
    return {
        attachment => $self->record->row_hash($attachment),
        idempotent => 1,
        ok         => 1,
    };
}

sub orphan_limit ( $, $input ) {
    if ( exists $input->{limit} && $input->{limit} ) {
        return $input->{limit};
    }

    return $ORPHAN_LIMIT;
}

sub orphan_reason ( $, $input ) {
    if (   exists $input->{reason}
        && defined $input->{reason}
        && length $input->{reason} )
    {
        return $input->{reason};
    }

    return $ORPHAN_REASON;
}

sub author_delete_reason ( $, $input ) {
    if (   exists $input->{reason}
        && defined $input->{reason}
        && length $input->{reason} )
    {
        return $input->{reason};
    }

    return $AUTHOR_DELETE_REASON;
}

sub orphan_actor ( $self, $attachment, $input ) {
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

sub orphan_search_attrs ( $self, $input ) {
    return {
        order_by => [ { -asc => 'created_at' } ],
        rows     => $self->orphan_limit($input),
    };
}

sub cleanup_result ( $, $deleted ) {
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

sub post_link_rows ( $, $post_ids ) {
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

=head2 already_scanned

True when the attachment is already clean and available, or infected and
quarantined. A failed scan is not terminal and may be retried.

=head2 scanned_replay

Returns the idempotent scan hash from the stored row.

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

=head2 author_delete_reason

Returns the delete reason, defaulting to C<author delete>.

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
