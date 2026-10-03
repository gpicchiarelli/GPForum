# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use English qw(-no_match_vars);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Schema;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run against PostgreSQL';
}

# Production connects as an ordinary role that owns its database, not as a
# superuser. Every connection ran SET lc_messages, which PostgreSQL allows
# only to a superuser, so such a role could neither migrate nor connect.
my $admin_dsn = $ENV{GPFORUM_DATABASE_DSN};
my $admin     = GPForum::Test::PostgresHarness::connect_dbi($admin_dsn);
my $role      = "gpf_plain_$PROCESS_ID";
my $name      = "gpforum_plain_$PROCESS_ID";
$admin->do(qq{CREATE ROLE "$role" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE});
$admin->do(qq{CREATE DATABASE "$name" OWNER "$role"});
( my $dsn = $admin_dsn ) =~ s/dbname=[^;]+/dbname=$name/msx;

{
    local $ENV{GPFORUM_DATABASE_DSN}      = $dsn;
    local $ENV{GPFORUM_DATABASE_USER}     = $role;
    local $ENV{GPFORUM_DATABASE_PASSWORD} = q{};

    is( GPForum::Test::PostgresHarness::prepare_database()->{migrate},
        0, 'a role without superuser migrates its own database' );

    my $schema =
      GPForum::Schema->connect_from_config( GPForum::Config->from_environment );
    my $dbh = $schema->storage->dbh;
    is(
        scalar $dbh->selectrow_array('SELECT count(*) FROM schema_versions') >
          0,
        1,
        'and the application connects as it'
    );
    is(
        scalar $dbh->selectrow_array(q{SELECT current_setting('lock_timeout')}),
        '3s',
        'with the session settings applied'
    );
    $schema->storage->disconnect;
}

$admin->do(qq{DROP DATABASE IF EXISTS "$name" WITH (FORCE)});
$admin->do(qq{DROP ROLE IF EXISTS "$role"});
$admin->disconnect;

done_testing();

1;
