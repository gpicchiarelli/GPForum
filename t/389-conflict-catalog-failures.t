# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::X::Conflict;
use GPForum::Test::FailingCatalogSchema;

our $VERSION = '0.001';

# A conflict reported on a partition's index is matched to its parent
# constraint through the catalog. When the catalog cannot be read -- its
# storage, handle, DBMS name or index lookup dies -- the conflict is matched
# on the constraint's own name alone, and nothing escapes from on(): the
# caller rethrows a conflict on another key instead of dying in the match. No
# test failed when any of these steps let its error through.
const my $PARTITION_CONFLICT =>
  'DBD::Pg::st execute failed: ERROR:  duplicate key value violates'
  . ' unique constraint "notifications_2026_10_pkey"';
const my @FAMILY => qw(notifications_pkey notifications_2026_10_pkey);

my $readable = GPForum::Test::FailingCatalogSchema->new( family => [@FAMILY] );
ok( _conflict($readable)->on('notifications_pkey'),
    'a readable catalog matches the partition index to its parent' );

for my $step (qw(storage dbh get_info select)) {
    my $schema = GPForum::Test::FailingCatalogSchema->new(
        fail_at => $step,
        family  => [@FAMILY],
    );
    my $conflict = _conflict($schema);

    my ( $on_parent, $error );
    try {
        $on_parent = $conflict->on('notifications_pkey');
    }
    catch ($caught) {
        $error = $caught;
    };
    is( $error, undef, "a catalog whose $step dies raises nothing" );
    ok( !$on_parent, "and gives no partitions to match ($step)" );
    ok(
        $conflict->on('notifications_2026_10_pkey'),
        "the reported index still matches by name ($step)"
    );
}

my $other = GPForum::Test::FailingCatalogSchema->new(
    dbms   => 'SQLite',
    family => [@FAMILY],
);
ok(
    !_conflict($other)->on('notifications_pkey'),
    'a handle that is not PostgreSQL gives no partitions'
);
is_deeply( $other->lookups, [], 'and is not asked for any' );

done_testing();

sub _conflict ($schema) {
    return GPForum::X::Conflict->from_error( $PARTITION_CONFLICT, $schema );
}

1;
