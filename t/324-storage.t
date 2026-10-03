# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::Storage;
use GPForum::Test::StorageProbeSchema;

our $VERSION = '0.001';

my $storage = 'GPForum::Infrastructure::Storage';

# A working schema answers with its storage and handle.
my $schema = _schema();
is( $storage->storage_of($schema), $schema, 'storage_of is the storage' );
is( $storage->dbh_of($schema),     'database handle', 'dbh_of is its handle' );

# Every way of having no handle is undef. A bare Mojo::Base object (the
# double loads Mojo::Base) has no storage method.
my %no_handle = (
    'no schema'                  => undef,
    'a schema that is no object' => { storage => 1 },
    'a class name'               => 'GPForum::Test::StorageProbeSchema',
    'a schema without storage'   => Mojo::Base->new,
    'a storage call that dies'   => _schema('storage'),
    'an undef storage'           => _schema('no_storage'),
    'a storage without dbh'      => _schema('no_dbh'),
    'a dbh call that dies'       => _schema('dbh'),
);
for my $case ( sort keys %no_handle ) {
    ok( !defined $storage->dbh_of( $no_handle{$case} ),
        "dbh_of is undef for $case" );
}

for my $case (
    'no schema',
    'a schema without storage',
    'a storage call that dies',
    'an undef storage'
  )
{
    ok( !defined $storage->storage_of( $no_handle{$case} ),
        "storage_of is undef for $case" );
}
ok(
    defined $storage->storage_of( _schema('dbh') ),
    'storage_of does not touch the handle'
);

# One value in list context, so a probe is safe as a hash value.
my %pairs = ( dbh => $storage->dbh_of(undef), next => 'kept' );
is( $pairs{next}, 'kept', 'an undef handle does not shift a hash' );
my @storage = $storage->storage_of(undef);
is( scalar @storage, 1, 'storage_of is one value in list context too' );

done_testing();

# A schema double whose named steps fail.
sub _schema (@fails) {
    return GPForum::Test::StorageProbeSchema->new(
        fails => { map { $_ => 1 } @fails } );
}

1;
