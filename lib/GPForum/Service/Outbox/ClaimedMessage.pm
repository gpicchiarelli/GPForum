# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Outbox::ClaimedMessage;

use strict;
use warnings;

use JSON::MaybeXS qw(decode_json);
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

has row            => sub { return {}; };
has update_handler => undef;

sub get_column ( $self, $column ) {
    return $self->_payload if $column eq 'payload';

    return $self->row->{$column};
}

sub update ( $self, $changes ) {
    if ( $self->update_handler ) {
        $self->update_handler->( $self, $changes );
    }

    $self->apply_columns($changes);

    return $self;
}

sub apply_columns ( $self, $changes ) {
    for my $column ( keys %{$changes} ) {
        $self->row->{$column} = $changes->{$column};
    }

    return $self;
}

sub is_direct_outbox_message {
    return 1;
}

sub _payload ($self) {
    my $payload = $self->row->{payload};
    return {}       if !defined $payload || $payload eq q{};
    return $payload if ref $payload;

    my $decoded = eval { return decode_json($payload); };
    return $decoded if ref $decoded eq 'HASH';

    return {};
}

1;
