# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::Storage;
use GPForum::Schema;

our $VERSION = '0.001';

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the storage probe test';
}

my $storage = 'GPForum::Infrastructure::Storage';
my %options = ( RaiseError => 1, PrintError => 0, AutoCommit => 1 );

# A real DBIx::Class schema: dbh_of connects and hands back a live handle.
my $schema = GPForum::Schema->connect(
    $ENV{GPFORUM_DATABASE_DSN},
    $ENV{GPFORUM_DATABASE_USER} // q{},
    $ENV{GPFORUM_DATABASE_PASSWORD} // q{}, \%options,
);
isa_ok( $storage->storage_of($schema), 'DBIx::Class::Storage::DBI' );
my $dbh = $storage->dbh_of($schema);
isa_ok( $dbh, 'DBI::db', 'dbh_of on a PostgreSQL schema' );
is( scalar $dbh->selectrow_array('SELECT 1'), 1, 'and the handle answers' );

# A server nobody listens on: the connection fails inside storage->dbh, and
# the probe is undef rather than the error.
my $unreachable = GPForum::Schema->connect(
    'dbi:Pg:dbname=postgres;host=127.0.0.1;port=1;connect_timeout=2',
    'nobody', q{}, \%options );
ok(
    defined $storage->storage_of($unreachable),
    'a schema that cannot connect still has storage'
);
ok( !defined $storage->dbh_of($unreachable),
    'but dbh_of is undef when the connection cannot be made' );

done_testing();

1;
