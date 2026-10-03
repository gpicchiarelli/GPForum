# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Attachment::Lifecycle;

use strict;
use warnings;

use Const::Fast;
use GPForum::Service::Attachment::Record;
use GPForum::Service::Clock;
use Mojo::Base -base, -signatures;
use POSIX        qw(strftime);
use Scalar::Util qw(blessed);

our $VERSION = '0.001';

const my $STATE_AVAILABLE      => 'available';
const my $STATE_DELETED        => 'deleted';
const my $STATE_INTENT         => 'intent';
const my $STATE_QUARANTINED    => 'quarantined';
const my $SCAN_CLEAN           => 'clean';
const my $SCAN_INFECTED        => 'infected';
const my $ORPHAN_LIMIT         => 100;
const my $ORPHAN_MIN_AGE       => 86_400;
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

# What the orphan purge asks again of the row it locked: one another run
# deleted, or an upload that went on, is no longer its to purge.
sub still_intent ( $self, $attachment ) {
    return $self->already_uploaded($attachment) ? 0 : 1;
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
        attachment => $self->row_columns($attachment),
        idempotent => 1,
        ok         => 1,
    };
}

# A stored row as a plain hash. Record::row_hash copies a hash, or a row with
# a data method -- which the fake ORM's rows had and no DBIx::Class row has:
# on PostgreSQL every replay built from a stored row came back empty, a
# replayed delete without its attachment and a replayed thumbnail without its
# columns.
sub row_columns ( $self, $row ) {
    if ( blessed($row) && $row->can('get_columns') ) {
        return { $row->get_columns };
    }

    return $self->record->row_hash($row);
}

sub orphan_limit ( $, $input ) {
    if ( exists $input->{limit} && $input->{limit} ) {
        return $input->{limit};
    }

    return $ORPHAN_LIMIT;
}

# How old an intent must be before the purge takes it for abandoned. An
# upload writes its bytes, then its intent, then moves it to uploaded within
# the same request: an intent younger than this may be one still in flight,
# and purging it would remove the file of an upload about to succeed. Only a
# whole number of seconds above zero is taken: zero, or a negative age, would
# put the cutoff at or after now and take every intent, the in-flight ones
# with them.
sub orphan_min_age ( $, $input ) {
    my $min_age = $input->{min_age};
    if (   defined $min_age
        && $min_age =~ /\A [[:digit:]]+ \z/msx
        && $min_age > 0 )
    {
        return int $min_age;
    }

    return $ORPHAN_MIN_AGE;
}

# From now_epoch alone, which every clock -- the test ones too -- answers.
sub orphan_cutoff ( $self, $input ) {
    return strftime '%Y-%m-%dT%H:%M:%SZ',
      gmtime( $self->clock->now_epoch - $self->orphan_min_age($input) );
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

# Not ok when an orphan could not be purged -- a file the storage would not
# remove -- so the timer that ran it is marked failed; the orphans before and
# after it are purged all the same.
sub cleanup_result ( $, $deleted, $errors = [] ) {
    if ( @{$errors} ) {
        return { deleted => $deleted, errors => $errors, ok => 0 };
    }

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

Owns upload replay, scan state transitions, delete replay hashes and the row
copies they are built from, orphan cleanup search/age/actor/reason policy,
and per-post link fetch caps. It does not write rows.
L<GPForum::Service::Attachment::Store> still updates attachments, deletes
orphans, and records events.

=head1 SUBROUTINES/METHODS

=head2 already_uploaded

True when the attachment has left the intent state.

=head2 still_intent

True when the attachment is still in the C<intent> state: the orphan purge
asks it again of the row it has locked, and leaves one another run deleted
or an upload moved on.

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

Returns the idempotent scan hash when status and state already match,
otherwise undef.

=head2 scan_matches

True when stored scan status and derived state match the input.

=head2 replaceable_verdicts

Takes the incoming scan status and returns an array reference of the
C<< { scan_status, state } >> pairs a stored row may hold for that verdict to
replace it, for the C<-or> of the scan C<UPDATE>. Verdicts only tighten: an
upload still C<pending> and C<uploaded> takes any verdict, and a C<clean>
and C<available> file may become infected or failed when a later scan finds
something. Nothing becomes clean over an infected or failed verdict, which
is what a slow clean racing a fast infected would otherwise do.

=head2 scan_changes

Returns the scan update columns, including C<quarantined_at> when needed.

=head2 already_deleted

True when the attachment is already deleted.

=head2 deleted_replay

Returns the idempotent delete hash,
C<< { ok => 1, idempotent => 1, attachment => \%columns } >>, with the
attachment's columns as L</row_columns> copies them.

=head2 row_columns

Takes a row -- a hash, a DBIx::Class row, or a row with C<data> -- and
returns its columns as a new plain hash (empty for no row). A DBIx::Class
row is read with C<get_columns>; anything else goes to
L<GPForum::Service::Attachment::Record/row_hash>, which does not understand
one. The store and L<GPForum::Service::Attachment::MediaProcessor> build
their replays with it.

=head2 orphan_limit

Returns the candidate row cap, defaulting to 100.

=head2 orphan_min_age

Returns the age in seconds an intent must reach before the purge takes it
for abandoned: C<min_age> from the input when it is a whole number of
seconds above zero, otherwise 86400 (one day). An upload moves its intent
to C<uploaded> within the request that wrote it, so a younger intent may be
an upload still in flight.

=head2 orphan_cutoff

Returns the creation time, as C<YYYY-MM-DDTHH:MM:SSZ>, at or before which an
intent is old enough to purge: L</orphan_min_age> seconds before the clock's
C<now_epoch>.

=head2 orphan_reason

Returns the delete reason, defaulting to C<orphan cleanup>.

=head2 author_delete_reason

Returns the delete reason, defaulting to C<author delete>.

=head2 orphan_actor

Returns the supplied actor id, otherwise the attachment owner.

=head2 orphan_where

Returns the intent-state search clause for orphan candidates. The store adds
the age (L</orphan_cutoff>) and the absence of links to it, so the row cap
counts orphans only.

=head2 orphan_search_attrs

Returns oldest-first search attributes including the row cap.

=head2 cleanup_result

Takes the array reference of deleted attachments and, optionally, one of
error messages. Returns C<< { ok => 1, deleted => \@deleted } >>, or with
errors C<< { ok => 0, deleted => \@deleted, errors => \@errors } >>.

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

None. The orphan defaults -- 100 candidates, a minimum age of one day -- are
constants here, overridden per call through the input hash.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<GPForum::Service::Attachment::Record>,
L<GPForum::Service::Clock>, L<Mojo::Base>, L<POSIX> and L<Scalar::Util>.

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
