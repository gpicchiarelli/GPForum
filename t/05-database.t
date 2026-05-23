package main;

use strict;
use warnings;

use Const::Fast;
use Mojo::File qw(path);
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Config;
use GPForum::Migration::Plan;
use GPForum::Schema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 13;

plan tests => $EXPECTED_TESTS;

my $schema = GPForum::Schema->clone;
my $source = $schema->source('SchemaVersion');

is( $source->from, 'schema_versions', 'schema version source maps table' );
is_deeply( [ $source->primary_columns ],
    ['version'], 'schema version primary key is explicit' );
ok( $source->has_column('checksum'), 'schema version records checksums' );
ok(
    $source->has_column('applied_at'),
    'schema version records application time'
);

my $config = GPForum::Config->from_environment(
    {
        GPFORUM_DATABASE_DSN  => 'dbi:Pg:dbname=gpforum_test',
        GPFORUM_DATABASE_USER => 'gpforum_test',
    }
);
my $connected_schema = GPForum::Schema->connect_from_config($config);

isa_ok( $connected_schema, 'GPForum::Schema' );
is( $connected_schema->storage->connect_info->[0],
    $config->database_dsn, 'schema uses configured database dsn' );

my $plan    = GPForum::Migration::Plan->new;
my $summary = $plan->summary;

is( scalar @{$summary},       1,     'one migration is planned' );
is( $summary->[0]->{version}, '001', 'migration version is parsed' );
is( $summary->[0]->{description},
    'foundation', 'migration description is parsed' );

my $migration_sql = path( $summary->[0]->{file} )->slurp;

like(
    $migration_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] schema_versions/msx,
    'migration creates schema_versions table'
);
like(
    $migration_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] event_log/msx,
    'migration creates event log table'
);
like(
    $migration_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] audit_log/msx,
    'migration creates audit log table'
);

throws_ok(
    sub {
        GPForum::Migration::Plan->new( directory => 'missing-migrations' )
          ->files;
    },
    qr/\A migration [ ] directory [ ] not [ ] found/msx,
    'missing migration directory fails clearly',
);

1;
