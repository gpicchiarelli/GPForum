# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Mojo::File qw(path);
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Migration::Runner;

our $VERSION = '0.001';

# The last migration written before the runner could build an index without
# a transaction. From the next one on, an index on a table that already
# exists is built CONCURRENTLY, in a no-transaction migration, or the file
# says why not (a partitioned parent cannot be built concurrently).
const my $LAST_BLOCKING => '048';
const my $INDEX_HEAD    => qr{CREATE [ ] (?:UNIQUE [ ])? INDEX}imsx;
const my $INDEX_TARGET  => qr{[ ] ON [ ] (?:ONLY [ ])? (\w+)}imsx;

my $runner = 'GPForum::Migration::Runner';
is_deeply(
    [ $runner->statements(<<'SQL') ],
-- gpforum:no-transaction
-- builds the index without stopping writes
DROP INDEX CONCURRENTLY IF EXISTS idx_a;
CREATE INDEX CONCURRENTLY idx_a
    ON posts (author_user_id);
SQL
    [
        'DROP INDEX CONCURRENTLY IF EXISTS idx_a',
        "CREATE INDEX CONCURRENTLY idx_a\n    ON posts (author_user_id)",
    ],
    'a no-transaction migration splits into its statements'
);
throws_ok(
    sub { $runner->statements("CREATE FUNCTION f() AS \$\$ SELECT 1; \$\$;\n") }
    ,
    qr/no [ ] [\$][\$] [ ] bodies/msx,
    'a dollar-quoted body is refused rather than split wrongly'
);

my @blocking;
for my $file ( sort { $a cmp $b } glob 'migrations/[0-9]*_*.sql' ) {
    my ($version) = path($file)->basename =~ /\A (\d+) _/msx;
    next if $version le $LAST_BLOCKING;

    my $sql = path($file)->slurp;
    next if $sql =~ /^ -- [ ] gpforum:blocking-index [ ] \S/msx;
    my %created =
      map { lc $_ => 1 }
      $sql =~ /CREATE [ ] TABLE [ ] (?:IF [ ] NOT [ ] EXISTS [ ])? (\w+)/gimsx;
    my $no_transaction = $sql =~ /\A -- [ ] gpforum:no-transaction \b/msx;
    while ( $sql =~ /($INDEX_HEAD [^;]*? $INDEX_TARGET)/gimsx ) {
        my ( $statement, $table ) = ( $1, lc $2 );
        next if $created{$table};
        next if $no_transaction && $statement =~ /CONCURRENTLY/imsx;
        push @blocking, "$file: $table";
    }
}
is_deeply( \@blocking, [],
    'every index on an existing table is built concurrently' );

done_testing();

1;
