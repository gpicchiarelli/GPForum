# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Worker::IdempotentJobRunner;

use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

our $VERSION = '0.001';

__PACKAGE__->requires(qw(store));

# The old order was ask, work, record. Nothing held the key between the
# question and the record, so two workers given the same event both passed the
# is_done check, both ran the side effect, and the loser's primary-key
# conflict was swallowed and reported as success.
#
# begin() now claims the key before any work happens and answers whether this
# worker owns it. A worker that does not own it stops here rather than
# duplicating the side effect.
sub run ( $self, $idempotency_key, $code, $event_id = undef ) {
    return { ok => 1, skipped => 1 }
      if $self->store->is_done($idempotency_key);

    return { ok => 1, skipped => 1 }
      if !$self->store->begin( $idempotency_key, $event_id );

    my $result;
    try {
        my $value = $code->();
        $self->store->mark_done( $idempotency_key, $value );
        $result = { ok => 1, skipped => 0, result => $value };
    }
    catch ($error) {
        $self->store->mark_failed( $idempotency_key, "$error" );
        $result = { ok => 0, skipped => 0, error => "$error" };
    };

    return $result;
}

1;
