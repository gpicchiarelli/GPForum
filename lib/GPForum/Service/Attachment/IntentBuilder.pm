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

