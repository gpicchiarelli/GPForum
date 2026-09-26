# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::Migrate;
use GPForum::Service::Admin::AuditReview;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $ALICE          => '018f1000-0000-7000-8000-00000000a11c';
const my $BOB            => '018f1000-0000-7000-8000-000000000b0b';
const my $TARGET         => '018f1000-0000-7000-8000-0000000000aa';
const my $CORRELATION    => '018f1000-0000-7000-8000-0000000000cc';
const my $PAGE           => 2;
const my $TOTAL_ROWS     => 7;
const my $ALICE_ENTRIES  => 3;
const my $WINDOW_ENTRIES => 5;
const my $PAGES_OF_TWO   => 4;
const my $INSERT_SQL => join q{ },
  'INSERT INTO audit_log (audit_id, action, schema_version, actor_id,',
  'target_type, target_id, correlation_id, created_at)',
  'VALUES (gen_random_uuid(), ?, 1, ?, ?, ?, ?, ?)';

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the audit viewer test';
}

# ADR 0079's audit viewer against the partitioned audit_log: every filter,
# the UTC date window, and keyset paging across rows that share a timestamp.
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
GPForum::Test::PostgresHarness::quietly(
    sub { return GPForum::Command::Migrate->new->run('--apply') } );

my $schema = GPForum::Test::PostgresHarness::connect_schema();
my $dbh    = $schema->storage->dbh;
my @rows   = (
    [
        'role_binding.created', $ALICE, 'role_binding', $TARGET,
        '2026-05-01T09:00:00Z'
    ],
    [
        'role_binding.revoked', $ALICE, 'role_binding', $TARGET,
        '2026-05-02T09:00:00Z'
    ],
    [ 'category.updated', $BOB,   'category', undef, '2026-05-03T09:00:00Z' ],
    [ 'category.updated', $BOB,   'category', undef, '2026-05-03T09:00:00Z' ],
    [ 'role.created',     $ALICE, 'role',     undef, '2026-05-04T09:00:00Z' ],
    [ 'role.created',     $BOB,   'role',     undef, '2026-05-05T09:00:00Z' ],
    [ 'role.created',     $BOB,   'role',     undef, '2026-05-06T23:59:59Z' ],
);
for my $row (@rows) {
    my ( $action, $actor, $type, $target, $at ) = @{$row};
    my $correlation =
      $action eq 'role_binding.created' ? $CORRELATION : _uuid($dbh);
    $dbh->do( $INSERT_SQL, undef, $action, $actor, $type, $target,
        $correlation, $at );
}

my $review = GPForum::Service::Admin::AuditReview->new( schema => $schema );

is( _count( { actor_id    => $ALICE } ), $ALICE_ENTRIES, 'filtered by actor' );
is( _count( { action      => 'category.updated' } ), 2,  'filtered by action' );
is( _count( { target_type => 'role_binding', target_id => $TARGET } ),
    2, 'filtered by target' );
is( _count( { correlation_id => $CORRELATION } ),
    1, 'looked up by correlation id' );
is( _count( { from => '2026-05-03', until => '2026-05-06' } ),
    $WINDOW_ENTRIES, 'filtered by a UTC date window, both days included' );
is( _count( { actor_id => $BOB, action => 'role.created' } ),
    2, 'filters combine' );

# Page through everything, two at a time, as the "older entries" link does.
my ( @seen, $cursor, $pages );
while (1) {
    my $page =
      $review->page( {}, { limit => $PAGE, after => $cursor } );
    push @seen, map { $_->get_column('audit_id') } @{ $page->{rows} };
    $pages++;
    $cursor = $page->{next_cursor};
    last if !$cursor;
}
is( scalar @seen, $TOTAL_ROWS, 'paging visits every row' );
is( scalar { map { $_ => 1 } @seen }->%*,
    $TOTAL_ROWS, 'once each, across the two rows that share a timestamp' );
is( $pages, $PAGES_OF_TWO, 'in pages of two' );

is(
    scalar
      @{ $review->page( {}, { limit => $PAGE, after => 'garbage' } )->{rows} },
    $PAGE,
    'a cursor that does not decode shows the first page'
);

# The indexes the filters were built for serve them.
for my $case (
    [ actor => { actor_id => $ALICE }, 'actor_id_created_at_idx' ],
    [
        action => { action => 'role.created' },
        'action_created_at_idx'
    ],
    [
        correlation_id => { correlation_id => $CORRELATION },
        'correlation_id_idx'
    ],
  )
{
    my ( $name, $filters, $index ) = @{$case};
    my $plan = GPForum::Test::PostgresHarness::plan_without_seqscan( $dbh,
        $review->page_resultset( $filters, { limit => $PAGE } ) );
    unlike( $plan, qr/Seq [ ] Scan/msx, "the $name filter reads an index" )
      or diag $plan;

    # Each partition carries its own copy of the parent's index, named
    # audit_log_<partition>_<columns>_idx.
    like( $plan, qr/\Q$index\E/msx, "the partitions' $index" );
}

$schema->storage->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _count {
    my ($filters) = @_;

    return
      scalar @{ $review->page( $filters, { limit => $TOTAL_ROWS } )->{rows} };
}

sub _uuid {
    my ($handle) = @_;

    return scalar $handle->selectrow_array('SELECT gen_random_uuid()');
}

1;
