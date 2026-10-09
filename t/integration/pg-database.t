# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp       qw(croak);
use English    qw(-no_match_vars);
use File::Temp qw(tempfile);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::PgDatabase;

our $VERSION = '0.001';

# A test whose subroutine names the clone, and one that dies between
# create_database and drop_database: each prints the name of its database.
my $HELD_BY_A_SUBROUTINE = <<'PERL';
use v5.40;
use lib 'lib';
use lib 't/lib';
use GPForum::Test::PgDatabase;
my $database = GPForum::Test::PgDatabase->fresh;
sub _reads_it { return $database->dbh->selectrow_array('SELECT 1') }
_reads_it();
print $database->name, "\n";
PERL
my $DIED_BEFORE_THE_DROP = <<'PERL';
use v5.40;
use lib 'lib';
use lib 't/lib';
use GPForum::Test::PgDatabase;
use GPForum::Test::PostgresHarness;
open STDERR, q{>}, q{/dev/null} or exit 2;
my $info = GPForum::Test::PostgresHarness::create_database(
    GPForum::Test::PgDatabase->admin_dsn );
print $info->{name}, "\n";
die "the test died before drop_database\n";
PERL

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run against PostgreSQL';
}

# The harness the fake-ORM tests move onto: a clone per test, of a template
# built once.
my $bare = GPForum::Test::PgDatabase->fresh;
is( _count( $bare, 'schema_versions' ) > 0, 1, 'a clone is migrated' );
is( _count( $bare, 'users' ),               0, 'and empty without the seed' );

my $seeded = GPForum::Test::PgDatabase->fresh( seed => 1 );
cmp_ok( _count( $seeded, 'users' ), q{>}, 0, 'the seeded clone has users' );

my $other = GPForum::Test::PgDatabase->fresh( seed => 1 );
$other->dbh->do('DELETE FROM user_feed_items');
$other->dbh->do('DELETE FROM notification_inbox');
is( _count( $other, 'user_feed_items' ), 0, 'a clone changes' );
isnt( $other->name, $seeded->name, 'on its own' );

my $name = $other->name;
undef $other;
is(
    scalar $seeded->dbh->selectrow_array(
        'SELECT count(*) FROM pg_database WHERE datname = ?',
        undef, $name
    ),
    0,
    'and is dropped when the test lets it go'
);

# Held by a subroutine, a clone lived into global destruction, where the
# admin handle was often freed before it and the drop never ran: four
# clones were left on the server by every full run.
_left_behind_by( $seeded, $HELD_BY_A_SUBROUTINE,
    'a clone a subroutine of the test holds is dropped when the test ends' );
_left_behind_by( $seeded, $DIED_BEFORE_THE_DROP,
    'a database a test died with before dropping it is dropped' );

done_testing();

# Runs the program in a perl of its own and checks the database it names is
# gone once it has ended; drops it if not, so a failure leaks nothing.
sub _left_behind_by {
    my ( $database, $program, $label ) = @_;

    my ( $handle, $file ) = tempfile( SUFFIX => '.pl', UNLINK => 1 );
    print {$handle} $program or croak "cannot write $file: $OS_ERROR";
    close $handle            or croak "cannot close $file: $OS_ERROR";

    # One program dies on purpose, and close then answers its exit status.
    open my $output, q{-|}, $EXECUTABLE_NAME, $file
      or croak "cannot run $file: $OS_ERROR";
    my $named = readline $output // q{};
    close $output or note("$file exited $CHILD_ERROR");
    chomp $named;

    my $dbh       = $database->dbh;
    my $remaining = $dbh->selectrow_array(
        'SELECT count(*) FROM pg_database WHERE datname = ?',
        undef, $named );
    ok( length $named && !$remaining, $label )
      or diag("left behind: $named");
    if ($remaining) {
        $dbh->do( 'DROP DATABASE IF EXISTS '
              . $dbh->quote_identifier($named)
              . ' WITH (FORCE)' );
    }

    return;
}

sub _count {
    my ( $database, $table ) = @_;

    return
      scalar $database->dbh->selectrow_array("SELECT count(*) FROM $table");
}

1;
