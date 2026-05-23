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

const my $EXPECTED_TESTS => 51;

plan tests => $EXPECTED_TESTS;

my $schema       = GPForum::Schema->clone;
my $source       = $schema->source('SchemaVersion');
my $event_source = $schema->source('EventLog');
my $audit_source = $schema->source('AuditLog');

is( $source->from, 'schema_versions', 'schema version source maps table' );
is_deeply( [ $source->primary_columns ],
    ['version'], 'schema version primary key is explicit' );
ok( $source->has_column('checksum'), 'schema version records checksums' );
ok(
    $source->has_column('applied_at'),
    'schema version records application time'
);

is( $event_source->from, 'event_log', 'event source maps event log table' );
is_deeply(
    [ $event_source->primary_columns ],
    [ 'event_id', 'created_at' ],
    'event log primary key is partition-safe'
);
ok( $event_source->has_column('event_type'), 'event log stores event type' );
ok(
    $event_source->has_column('schema_version'),
    'event log stores schema version'
);
ok(
    $event_source->has_column('correlation_id'),
    'event log stores correlation id'
);
ok( $event_source->has_column('causation_id'),
    'event log stores causation id' );
ok(
    $event_source->has_column('idempotency_key'),
    'event log stores idempotency key'
);
ok( $event_source->has_column('payload'), 'event log stores payload' );

is( $audit_source->from, 'audit_log', 'audit source maps audit log table' );
is_deeply(
    [ $audit_source->primary_columns ],
    [ 'audit_id', 'created_at' ],
    'audit log primary key is partition-safe'
);
ok( $audit_source->has_column('action'), 'audit log stores action' );
ok(
    $audit_source->has_column('schema_version'),
    'audit log stores schema version'
);
ok(
    $audit_source->has_column('correlation_id'),
    'audit log stores correlation id'
);
ok( $audit_source->has_column('metadata'), 'audit log stores metadata' );

my $user_source       = $schema->source('User');
my $credential_source = $schema->source('Credential');
my $session_source    = $schema->source('Session');

is( $user_source->from, 'users', 'user source maps users table' );
is_deeply( [ $user_source->primary_columns ],
    ['id'], 'user primary key is explicit' );
ok( $user_source->has_column('email_normalized'),
    'user stores normalized email' );
ok(
    $user_source->has_column('email_verified_at'),
    'user supports email verification placeholder'
);
ok(
    $user_source->has_relationship('credentials'),
    'user has credentials relationship'
);
ok( $user_source->has_relationship('sessions'),
    'user has sessions relationship' );

is( $credential_source->from, 'credentials',
    'credential source maps credentials table' );
ok(
    $credential_source->has_column('secret_hash'),
    'credential stores only secret hash'
);
ok( $credential_source->has_relationship('user'),
    'credential belongs to user' );

is( $session_source->from, 'sessions', 'session source maps sessions table' );
is_deeply( [ $session_source->primary_columns ],
    ['session_id'], 'session primary key is explicit' );
ok( $session_source->has_column('session_hash'), 'session stores token hash' );
ok( $session_source->has_column('revoked_at'), 'session supports revocation' );
ok( $session_source->has_relationship('user'), 'session belongs to user' );

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

is( scalar @{$summary},       2,     'two migrations are planned' );
is( $summary->[0]->{version}, '001', 'migration version is parsed' );
is(
    $summary->[0]->{description},
    'core identity',
    'migration description is parsed'
);

my $migration_sql = path( $summary->[0]->{file} )->slurp;

like(
    $migration_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] schema_versions/msx,
    'migration creates schema_versions table'
);
like(
    $migration_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] users/msx,
    'core identity migration creates users table'
);
like(
    $migration_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] credentials/msx,
    'core identity migration creates credentials table'
);
like(
    $migration_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] sessions/msx,
    'core identity migration creates sessions table'
);
like(
    $migration_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] roles/msx,
    'core identity migration creates roles table'
);
like(
    $migration_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] role_bindings/msx,
    'core identity migration creates role bindings table'
);
like(
    $migration_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] resource_acl/msx,
    'core identity migration creates resource acl table'
);

my $event_audit_sql = path( $summary->[1]->{file} )->slurp;

is( $summary->[1]->{description},
    'event audit', 'event audit migration description is parsed' );
like(
    $event_audit_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] event_log/msx,
    'event audit migration creates event log table'
);
like(
    $event_audit_sql,
    qr/PARTITION [ ] BY [ ] RANGE [ ] [(] created_at [)]/msx,
    'event audit migration partitions append logs by created_at'
);
like(
    $event_audit_sql,
qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] event_idempotency_keys/msx,
    'event audit migration creates global idempotency table'
);
like(
    $event_audit_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] audit_log/msx,
    'event audit migration creates audit log table'
);
like(
    $event_audit_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] outbox_jobs/msx,
    'event audit migration creates outbox jobs table'
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
