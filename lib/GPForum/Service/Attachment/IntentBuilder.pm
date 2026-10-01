# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Attachment::IntentBuilder;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

use GPForum::Service::Clock;

our $VERSION = '0.001';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};

sub build_intent ( $self, $values ) {
    my $attachment_id = $self->id_service->uuid;

    return {
        attachment_id     => $attachment_id,
        owner_user_id     => $values->{owner_user_id},
        object_key        => _object_key( $values, $attachment_id ),
        original_filename => $values->{original_filename},
        media_type        => $values->{media_type},
        byte_size         => $values->{byte_size},
        checksum          => $values->{checksum},
        state             => 'intent',
        scan_status       => 'pending',
        scan_attempts     => 0,
        created_at        => $self->clock->now_iso8601,
        uploaded_at       => undef,
        scanned_at        => undef,
        quarantined_at    => undef,
        deleted_at        => undef,
    };
}

sub _object_key ( $values, $attachment_id ) {
    return join q{/}, 'attachments', $values->{owner_user_id}, $attachment_id;
}

1;

__END__

=head1 NAME

GPForum::Service::Attachment::IntentBuilder - The record an attachment starts as, before its bytes arrive.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $builder = GPForum::Service::Attachment::IntentBuilder->new;
    my $intent  = $builder->build_intent( $validation->{values} );
    # state 'intent', scan_status 'pending',
    # object_key "attachments/$owner_user_id/$attachment_id"

=head1 DESCRIPTION

Turns validated upload values, as L<GPForum::Service::Attachment::Validator>
returns them, into a new attachment record in the C<intent> state: a fresh
uuid, an object key under the owner's prefix, the scan pending with no
attempts, and C<created_at> from the clock; the upload, scan, quarantine and
deletion times start empty. It writes nothing; the caller stores the hash.

=head1 SUBROUTINES/METHODS

=head2 build_intent

Takes a hash reference with C<owner_user_id>, C<original_filename>,
C<media_type>, C<byte_size> and C<checksum>. Returns the attachment hash:
C<attachment_id>, C<owner_user_id>, C<object_key>
(C<attachments/OWNER_USER_ID/ATTACHMENT_ID>), the four other values as
given, C<state> C<intent>, C<scan_status> C<pending>, C<scan_attempts> 0,
C<created_at>, and undef C<uploaded_at>, C<scanned_at>, C<quarantined_at>
and C<deleted_at>.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Clock>, L<GPForum::Infrastructure::Id> (loaded when
first needed).

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
