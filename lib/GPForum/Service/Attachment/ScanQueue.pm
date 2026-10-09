# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Attachment::ScanQueue;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Service::Attachment::Record;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $STATE_UPLOADED    => 'uploaded';
const my $STATE_AVAILABLE   => 'available';
const my $SCAN_PENDING      => 'pending';
const my $SCAN_CLEAN        => 'clean';
const my $FORMAT_CHECK      => 'format-check';
const my $SCAN_ERROR_LENGTH => 500;

has clock  => sub { return GPForum::Service::Clock->new; };
has record => sub { return GPForum::Service::Attachment::Record->new; };
__PACKAGE__->requires(qw(schema));

# Uploads no scanner has decided yet, oldest first: what the scheduled rescan
# retries once the antivirus answers again (ADR 0108).
sub pending_scan_ids ( $self, $limit ) {
    return $self->_ids_by_attempts(
        {
            deleted_at  => undef,
            scan_status => $SCAN_PENDING,
            state       => $STATE_UPLOADED,
        },
        'uploaded_at',
        $limit
    );
}

# Files served on a format check alone, oldest first: the backfill's work
# once an antivirus is configured (ADR 0108).
sub unscanned_clean_ids ( $self, $limit ) {
    return $self->_ids_by_attempts(
        _format_checked( { state => $STATE_AVAILABLE } ),
        'created_at', $limit );
}

# Fewest scan attempts first, then oldest by the age column, then id.
sub _ids_by_attempts ( $self, $where, $age_column, $limit ) {
    my $search = $self->_attachments->search_rs(
        $where,
        {
            columns  => ['attachment_id'],
            order_by => [
                { -asc => 'scan_attempts' },
                { -asc => $age_column },
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
    my $attachment = $self->_attachments->find($attachment_id);
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

1;

__END__

=head1 NAME

GPForum::Service::Attachment::ScanQueue - The scheduled rescan's and the antivirus backfill's work on attachment rows.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $queue = GPForum::Service::Attachment::ScanQueue->new(
        schema => $schema );

    for my $attachment_id ( @{ $queue->pending_scan_ids(50) } ) {
        ...;    # scan it again; on failure:
        $queue->record_scan_failure( $attachment_id, $error );
    }
    for my $attachment_id ( @{ $queue->unscanned_clean_ids(50) } ) {
        ...;    # scan it; when the engine finds it clean:
        $queue->confirm_clean(
            { attachment_id => $attachment_id, scan_engine => 'clamd' } );
    }

=head1 DESCRIPTION

The queues of ADR 0108, over the C<attachments> table: the uploads no
scanner has decided yet, which the scheduled rescan retries once the
antivirus answers again, and the files served on a format check alone,
which the backfill scans once an antivirus is configured. Both are taken
fewest scan attempts first, so a file that keeps failing does not hold up
the others. Verdicts themselves, with their events, are written by
L<GPForum::Service::Attachment::Store/record_scan>; the store also answers
every method here by delegation, which is how the scanner and the
scheduled jobs reach it.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor. C<schema> is required. C<clock>
(L<GPForum::Service::Clock>) and C<record>
(L<GPForum::Service::Attachment::Record>) have defaults.

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

=head1 DIAGNOSTICS

Database errors propagate. An unknown id is answered, not thrown.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<GPForum::Base>, L<GPForum::Service::Attachment::Record>,
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
