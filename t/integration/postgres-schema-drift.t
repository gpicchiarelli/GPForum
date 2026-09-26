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
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $COLUMNS_SQL => join q{ },
  'SELECT column_name, data_type, is_nullable',
  'FROM information_schema.columns',
  'WHERE table_schema = current_schema() AND table_name = ?';
const my $PRIMARY_KEY_SQL => join q{ },
  'SELECT a.attname FROM pg_index i JOIN pg_attribute a',
  'ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)',
  'WHERE i.indrelid = ?::regclass AND i.indisprimary',
  'ORDER BY array_position(i.indkey, a.attnum)';
const my $UNIQUE_INDEX_SQL => join q{ },
  'SELECT c.relname AS name, pg_get_expr(i.indpred, i.indrelid) AS predicate,',
  '(i.indexprs IS NOT NULL) AS has_expressions,',
  q{(SELECT string_agg(a.attname, ',' ORDER BY a.attname)},
  'FROM pg_attribute a WHERE a.attrelid = i.indrelid',
  'AND a.attnum = ANY (i.indkey)) AS columns',
  'FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid',
  'WHERE i.indrelid = ?::regclass AND i.indisunique AND NOT i.indisprimary';

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the schema drift test';
}

# Two descriptions of one schema: the migrations, which build it, and the
# DBIx::Class Result classes, which the application reads and writes through.
# Nothing compared them. This does, against the schema the migrations
# actually leave behind -- every table, column, type, nullability, primary key
# and unique key.
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};

is(
    GPForum::Test::PostgresHarness::quietly(
        sub { return GPForum::Command::Migrate->new->run('--apply') }
    ),
    0,
    'migrations apply'
);

my $schema = GPForum::Test::PostgresHarness::connect_schema();
my $dbh    = $schema->storage->dbh;
my %drift  = map { $_ => [] } qw(tables columns types nullability keys unique);

my @monikers = sort $schema->sources;
for my $moniker (@monikers) {
    _compare( $moniker, $schema->source($moniker) );
}

cmp_ok( scalar @monikers, q{>}, 0, 'every Result class was examined' );
for my $aspect (qw(tables columns types nullability keys unique)) {
    is_deeply( $drift{$aspect}, [],
        "the Result classes and the database agree on $aspect" )
      or diag join "\n", @{ $drift{$aspect} };
}

$schema->storage->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _compare {
    my ( $moniker, $source ) = @_;

    my $table = $source->name;
    my $columns =
      $dbh->selectall_hashref( $COLUMNS_SQL, 'column_name', undef, $table );
    if ( !%{$columns} ) {
        push @{ $drift{tables} }, "$moniker: table $table does not exist";
        return;
    }

    _compare_columns( $moniker, $source, $columns );
    _compare_primary_key( $moniker, $source );
    _compare_unique( $moniker, $source );

    return;
}

sub _compare_columns {
    my ( $moniker, $source, $columns ) = @_;

    my %declared = map { $_ => 1 } $source->columns;
    for my $column ( $source->columns ) {
        my $actual = $columns->{$column};
        if ( !$actual ) {
            push @{ $drift{columns} }, "$moniker.$column: not in the database";
            next;
        }
        my $info = $source->column_info($column);
        my $type = lc( $info->{data_type} // q{} );
        if ( $type ne $actual->{data_type} ) {
            push @{ $drift{types} },
              "$moniker.$column: Result says $type, database says"
              . " $actual->{data_type}";
        }
        my $nullable = $actual->{is_nullable} eq 'YES' ? 1 : 0;
        if ( $nullable != ( $info->{is_nullable} ? 1 : 0 ) ) {
            push @{ $drift{nullability} },
              "$moniker.$column: nullable in the "
              . ( $nullable ? 'database' : 'Result class' ) . ' only';
        }
    }
    push @{ $drift{columns} }, map { "$moniker.$_: not in the Result class" }
      grep { !$declared{$_} } sort keys %{$columns};

    return;
}

sub _compare_primary_key {
    my ( $moniker, $source ) = @_;

    my $actual =
      join q{,},
      @{ $dbh->selectcol_arrayref( $PRIMARY_KEY_SQL, undef, $source->name ) };
    my $declared = join q{,}, $source->primary_columns;
    if ( $actual ne $declared ) {
        push @{ $drift{keys} },
          "$moniker: primary key ($declared) in the Result class,"
          . " ($actual) in the database";
    }

    return;
}

# A declared unique key must be a unique index of the same name and columns.
# DBIx::Class cannot express a partial one, so the index may be partial only on
# its own columns being NOT NULL, which changes nothing for a lookup by value.
# Every full unique index must in turn be declared, or find() cannot use it.
sub _compare_unique {
    my ( $moniker, $source ) = @_;

    my %index = map { $_->{name} => $_ } @{
        $dbh->selectall_arrayref( $UNIQUE_INDEX_SQL, { Slice => {} },
            $source->name )
    };
    my %declared = $source->unique_constraints;
    delete $declared{primary};

    for my $name ( sort keys %declared ) {
        my $columns = join q{,}, sort @{ $declared{$name} };
        my $actual  = $index{$name};
        if ( !$actual || $actual->{columns} ne $columns ) {
            if ( !_null_guard_only( $actual->{predicate}, $declared{$name} ) ) {
                push @{ $drift{unique} },
"$moniker: $name ($columns) is not a unique index in the database";
                next;
            }
            push @{ $drift{unique} },
              "$moniker: $name is partial on $actual->{predicate},"
              . ' which a Result class cannot express';
        }
    }
    for my $name ( sort keys %index ) {
        my $actual = $index{$name};
        next if defined $actual->{predicate} || $actual->{has_expressions};
        if ( !$declared{$name} ) {
            push @{ $drift{unique} },
"$moniker: unique index $name ($actual->{columns}) is not declared";
        }
    }

    return;
}

sub _null_guard_only {
    my ( $predicate, $columns ) = @_;

    return 1 if !defined $predicate;

    my %key = map { $_ => 1 } @{$columns};
    for my $term ( split /\s+ AND \s+/msx, $predicate ) {
        my ($column) =
          $term =~ /\A [(]* (\w+) \s+ IS \s+ NOT \s+ NULL [)]* \z/msx;
        return 0 if !$column || !$key{$column};
    }

    return 1;
}

1;
