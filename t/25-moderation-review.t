# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Moderation::SuspensionStore;
use GPForum::Test::UnreachableSchema;

our $VERSION = '0.001';

# The moderation stores and the review reader are tested on PostgreSQL, in
# t/integration/postgres-moderation-review.t: reports through assignment,
# release and resolution; hide, restore, lock and reversal, each idempotent
# when repeated; suspensions and their revocation; and the keyset pages of
# the review lists, each with the event, outbox message and audit entry it
# leaves. They ran here on a fake ORM, which let ActionStore write a
# hidden_at no thread has and kept timestamps as the strings it was given,
# so neither defect could show.
#
# What stays is what never reaches the database: without a user id there is
# nothing to look up, and the schema, which dies when reached, is never asked.
my $store = GPForum::Service::Moderation::SuspensionStore->new(
    schema => GPForum::Test::UnreachableSchema->new );
is( $store->active_for_user(undef),
    undef, 'no user id has no active suspension, without a query' );
is( $store->active_for_user(q{}),
    undef, 'nor has an empty user id, without a query' );

done_testing();

1;
