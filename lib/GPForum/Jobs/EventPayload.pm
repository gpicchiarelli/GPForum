# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Jobs::EventPayload;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

sub normalize ( $self, $payload ) {
    return {} if ref $payload ne 'HASH';

    my %normalized = %{$payload};
    if (  !exists $normalized{domain_payload}
        && ref $payload->{payload} eq 'HASH' )
    {
        $normalized{domain_payload} = $payload->{payload};
    }

    if ( ref $payload->{aggregate} eq 'HASH' ) {
        $normalized{aggregate_id}      //= $payload->{aggregate}{id};
        $normalized{aggregate_type}    //= $payload->{aggregate}{type};
        $normalized{aggregate_version} //= $payload->{aggregate}{version};
    }

    if ( ref $payload->{actor} eq 'HASH' && !defined $normalized{actor_id} ) {
        $normalized{actor_id} = $payload->{actor}{id};
    }

    return \%normalized;
}

1;
