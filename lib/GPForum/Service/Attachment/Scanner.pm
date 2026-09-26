# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Attachment::Scanner;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

use GPForum::Service::Attachment::Validator;

our $VERSION = '0.001';

const my $SCANNER_ACTOR => 'attachment-scanner';
const my $SCAN_CLEAN    => 'clean';
const my $SCAN_FAILED   => 'failed';
const my $SCAN_INFECTED => 'infected';
const my $FORMAT_CHECK  => 'format-check';

# The system antivirus (ADR 0108), or undef when scanning is off.
has antivirus => undef;
has storage   => undef;
has store     => undef;
has validator => sub { return GPForum::Service::Attachment::Validator->new; };

# Decides one upload that is still pending, idempotently: a verdict already
# recorded is replayed, not recomputed. Dies when the antivirus cannot answer,
# so the caller -- the outbox, or the scheduled rescan -- retries later.
sub scan ( $self, $attachment_id ) {
    my $attachment = $self->store->find_attachment($attachment_id);
    if ( !$attachment ) {
        return { error => 'not_found', ok => 0 };
    }

    my $replayed = $self->store->terminal_scan($attachment);
    if ($replayed) {
        return $replayed;
    }

    # Deleted while it waited: there is nothing to decide, and scanning it
    # would only cost a read. record_scan would refuse to revive it anyway.
    if ( defined $self->store->record->column( $attachment, 'deleted_at' ) ) {
        return {
            attachment_id => $attachment_id,
            ok            => 1,
            skipped       => 'deleted'
        };
    }

    return $self->_scan_bytes( $attachment, $attachment_id );
}

# Whether a batch is worth starting. Without an antivirus the format check
# needs nothing; with one, it must answer, or every file would fail alike.
sub antivirus_available ($self) {
    return 1 if !$self->antivirus;

    return $self->antivirus->available ? 1 : 0;
}

# A file served on a format check alone -- uploaded before scanning existed,
# or while it was off -- put through the antivirus. Malware or changed bytes
# quarantine it: a verdict may tighten. Clean records the engine, so the file
# is not scanned again.
sub backfill ( $self, $attachment_id ) {
    return { ok => 1, skipped => 'no antivirus' } if !$self->antivirus;

    my $attachment = $self->store->find_attachment($attachment_id);
    return { error => 'not_found', ok => 0 } if !$attachment;

    my $input =
      $self->_scan_input( $attachment, $self->_read_object($attachment) );
    if ( $input->{scan_status} eq $SCAN_CLEAN ) {
        return $self->store->confirm_clean($input);
    }

    return $self->store->record_scan($input);
}

sub _scan_bytes ( $self, $attachment, $attachment_id ) {
    return $self->store->record_scan(
        $self->_scan_input( $attachment, $self->_read_object($attachment) ) );
}

# A read that fails says nothing about the file either: the storage may be
# briefly unavailable. Dying leaves the upload pending, unserved, for the
# outbox and the hourly rescan to try again -- a permanent 'failed' for a
# transient error would lose the upload.
sub _read_object ( $self, $attachment ) {
    my $key     = $self->store->record->column( $attachment, 'object_key' );
    my $content = eval { return $self->storage->read_object($key); };
    if ( !defined $content ) {
        croak "cannot read stored object $key: " . ( $EVAL_ERROR || 'missing' );
    }

    return $content;
}

# The verdict for an upload the request could not decide. The stored bytes
# must still sniff to the declared media type -- a mismatch means they changed
# after the write, and is recorded as failed, not infected: it is not malware.
# Then the system antivirus decides.
sub _scan_input ( $self, $attachment, $content ) {
    my $attachment_id =
      $self->store->record->column( $attachment, 'attachment_id' );
    my %input = (
        actor_id      => $SCANNER_ACTOR,
        attachment_id => $attachment_id,
    );

    if ( !$self->_same_media( $attachment, $content ) ) {
        return {
            %input,
            reason      => 'media mismatch',
            scan_engine => $FORMAT_CHECK,
            scan_status => $SCAN_FAILED,
        };
    }
    if ( !$self->antivirus ) {
        return {
            %input,
            scan_engine => $FORMAT_CHECK,
            scan_status => $SCAN_CLEAN
        };
    }

    return {
        %input,
        _antivirus_fields( $self->antivirus->scan($content), $attachment_id )
    };
}

# An antivirus that could not answer has said nothing about the file. Dying
# hands the event back to the outbox, which retries with backoff and records a
# dead letter after its last attempt; the attachment stays pending meanwhile,
# and pending is never served.
sub _antivirus_fields ( $verdict, $attachment_id ) {
    if ( $verdict->{status} eq 'error' ) {
        croak "antivirus could not scan attachment $attachment_id:"
          . " $verdict->{error}";
    }

    return (
        reason => $verdict->{status} eq $SCAN_INFECTED
        ? "malware: $verdict->{signature}"
        : undef,
        scan_engine    => $verdict->{engine},
        scan_signature => $verdict->{signature},
        scan_status    => $verdict->{status},
    );
}

sub _same_media ( $self, $attachment, $content ) {
    my $sniffed = $self->validator->sniff_media_type($content);
    my $stored  = $self->store->record->column( $attachment, 'media_type' );
    if ( _text($sniffed) eq _text($stored) ) {
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

1;

__END__

=head1 NAME

GPForum::Service::Attachment::Scanner - Decide a pending upload.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $verdict = $scanner->scan($attachment_id);

=head1 DESCRIPTION

Reaches the verdict an upload could not reach inside its request (ADR 0108):
the stored bytes must still sniff to the declared media type, then the system
antivirus decides. Used by the attachment worker for each upload event and by
the scheduled rescan of uploads left pending.

=head1 SUBROUTINES/METHODS

=head2 scan

Records and returns the verdict for one attachment; replays a verdict already
recorded. A mismatch is C<failed>, not C<infected>.

=head2 backfill

Scans a file that was served on a format check alone: quarantines it if the
antivirus finds something, otherwise records the engine that confirmed it.

=head2 antivirus_available

False when an antivirus is configured and does not answer.

=head1 DIAGNOSTICS

Dies when the antivirus cannot answer, so the caller retries; the attachment
stays pending and unserved.

=head1 CONFIGURATION AND ENVIRONMENT

The antivirus comes from L<GPForum::Infrastructure::Antivirus>.

=head1 DEPENDENCIES

L<GPForum::Service::Attachment::Validator>, L<Mojo::Base>.

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
