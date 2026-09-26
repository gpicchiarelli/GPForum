# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Jobs::EventPayload;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

sub normalize ( $self, $payload ) {
    return {} if ref $payload ne 'HASH';

    my %normalized = %{$payload};
    $normalized{domain_payload} = $payload->{payload}
      if !exists $normalized{domain_payload}
      && ref $payload->{payload} eq 'HASH';

    if ( ref $payload->{aggregate} eq 'HASH' ) {
        $normalized{aggregate_id} = $payload->{aggregate}{id}
          if !defined $normalized{aggregate_id};
        $normalized{aggregate_type} = $payload->{aggregate}{type}
          if !defined $normalized{aggregate_type};
        $normalized{aggregate_version} = $payload->{aggregate}{version}
          if !defined $normalized{aggregate_version};
    }

    if ( ref $payload->{actor} eq 'HASH' && !defined $normalized{actor_id} ) {
        $normalized{actor_id} = $payload->{actor}{id};
    }

    return \%normalized;
}

1;
