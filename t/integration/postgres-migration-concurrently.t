# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Migration::Plan;
use GPForum::Migration::Runner;
use GPForum::Test::PgDatabase;

our $VERSION = '0.001';

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run against PostgreSQL';
}

# A migration builds an index without stopping writes only with CREATE INDEX
# CONCURRENTLY, which PostgreSQL refuses inside a transaction block -- and
# the runner sent each file whole, which is one. A no-transaction migration
# runs its statements one at a time.
my $concurrent = <<'SQL';
DROP INDEX CONCURRENTLY IF EXISTS idx_test_posts_author_created;
CREATE INDEX CONCURRENTLY idx_test_posts_author_created
    ON posts (author_user_id, created_at);
SQL

my ( $blocked, $blocked_error ) = _apply($concurrent);
ok( !$blocked, 'sent whole, a concurrent index build is refused' );
like(
    $blocked_error,
    qr/transaction [ ] block/msx,
    'because it would run inside a transaction block'
);

my ( $built, $error ) = _apply("-- gpforum:no-transaction\n$concurrent");
ok( $built, 'marked no-transaction, it runs' ) or diag $error;
is( $built->{valid},    1, 'and the index is valid' );
is( $built->{recorded}, 1, 'and the migration is recorded once' );

done_testing();

# Applies the project's migrations plus one more, numbered 900, to a fresh
# copy of the migrated schema: only the new one is pending.
sub _apply {
    my ($sql) = @_;

    my $database  = GPForum::Test::PgDatabase->fresh;
    my $directory = path( tempdir( CLEANUP => 1 ) );
    for my $file ( path('migrations')->list->each ) {
        $file->copy_to( $directory->child( $file->basename ) );
    }
    $directory->child('900_test_concurrent_index.sql')->spew($sql);

    my $runner = GPForum::Migration::Runner->new(
        applied_by => 'test',
        plan   => GPForum::Migration::Plan->new( directory => "$directory" ),
        schema => $database->schema,
    );
    my $applied = eval { $runner->apply_pending; 1 };
    return ( undef, $EVAL_ERROR ) if !$applied;

    my $dbh = $database->dbh;
    return {
        recorded => scalar $dbh->selectrow_array(
            q{SELECT count(*) FROM schema_versions WHERE version = '900'}),
        valid => scalar $dbh->selectrow_array(
                q{SELECT count(*) FROM pg_index i JOIN pg_class c}
              . q{ ON c.oid = i.indexrelid}
              . q{ WHERE c.relname = 'idx_test_posts_author_created'}
              . q{ AND i.indisvalid}
        ),
    };
}

1;
