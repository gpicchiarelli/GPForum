# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(JSON);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::UniqueConflict;
use GPForum::X;
use GPForum::X::Argument;
use GPForum::X::Check;
use GPForum::X::Config;
use GPForum::X::Conflict;
use GPForum::X::Unavailable;
use GPForum::X::Usage;
use GPForum::Test::ConflictCatalogSchema;

our $VERSION = '0.001';

# A unique violation as DBIx::Class hands it over: the server's sentence, its
# DETAIL line, and the statement and parameter values DBI appends.
const my $DBI_CONFLICT =>
  'DBIx::Class::Storage::DBI::_dbh_execute(): DBI Exception:'
  . ' DBD::Pg::st execute failed: ERROR:  duplicate key value violates'
  . ' unique constraint "notifications_2026_10_pkey"'
  . "\nDETAIL:  Key (notification_id)=(n-1) already exists."
  . ' [for Statement "INSERT INTO notifications" with ParamValues: 1=n-1]';

# No unique violation in the server's sentence; a member's text in the
# parameter values says "unique constraint".
const my $SPOOFED => 'DBD::Pg::st execute failed: ERROR:  value too long'
  . ' [for Statement "INSERT INTO posts" with ParamValues:'
  . ' 1=unique constraint "posts_pkey"]';

const my %FAILURE_TYPE => (
    'GPForum::X'              => 'transient',
    'GPForum::X::Argument'    => 'permanent',
    'GPForum::X::Check'       => 'permanent',
    'GPForum::X::Config'      => 'permanent',
    'GPForum::X::Conflict'    => 'transient',
    'GPForum::X::Unavailable' => 'transport',
    'GPForum::X::Usage'       => 'permanent',
);

# The hierarchy and what the outbox reads from each class.
for my $class ( sort keys %FAILURE_TYPE ) {
    my $error = $class->new( message => 'it broke' );
    isa_ok( $error, 'GPForum::X', $class );
    is( $error->failure_type, $FAILURE_TYPE{$class},
        "$class declares failure_type $FAILURE_TYPE{$class}" );
}

# The string is the message, and only the message.
my $usage = GPForum::X::Usage->new( message => 'Usage: bin/gpforum-migrate' );
is( "$usage", 'Usage: bin/gpforum-migrate', 'it stringifies to its message' );
ok( $usage eq 'Usage: bin/gpforum-migrate', 'and compares as that string' );
like( $usage, qr/\A Usage: /msx, 'so the regexes reading croaks still match' );
ok( GPForum::X->new( message => '0' ),
    'it is true even when its message is 0' );
is(
    JSON->new->convert_blessed->encode( { error => $usage } ),
    '{"error":"Usage: bin/gpforum-migrate"}',
    'it encodes in JSON as its message'
);

# A message is required.
my $missing = _error_of( sub { GPForum::X::Check->new } );
ok( GPForum::X::Argument->caught($missing),
    'an exception without a message throws an X::Argument' );
is( "$missing", 'GPForum::X::Check requires message', 'naming its class' );

# throw, caught, rethrow.
my $line;
my $thrown = _error_of(
    sub {
        $line = __LINE__ + 1;
        GPForum::X::Unavailable->throw( message => 'clamd is down' );
    }
);
ok( GPForum::X::Unavailable->caught($thrown), 'throw croaks the object' );
is(
    $thrown->location,
    "t/322-exceptions.t line $line",
    'and records where it was thrown'
);
is( "$thrown", 'clamd is down',           'which stays out of the string' );
is( GPForum::X->caught($thrown), $thrown, 'caught answers for a base class' );
ok( !defined GPForum::X::Config->caught($thrown), 'not for a sibling' );
ok( !defined GPForum::X->caught('clamd is down'), 'nor for a string' );
ok( !defined GPForum::X->caught(undef),           'nor for nothing' );

my $again = _error_of( sub { $thrown->rethrow } );
is( $again, $thrown, 'rethrow croaks the same object' );
is(
    $again->location,
    "t/322-exceptions.t line $line",
    'keeping where it was first thrown'
);

# X::Conflict reads the server's sentence.
my $conflict = GPForum::X::Conflict->from_error($DBI_CONFLICT);
isa_ok( $conflict, 'GPForum::X::Conflict', 'a unique violation' );
is( "$conflict",      $DBI_CONFLICT, 'stringifies to the original DBI text' );
is( $conflict->cause, $DBI_CONFLICT, 'and keeps it as its cause' );
is( $conflict->constraint, 'notifications_2026_10_pkey',
    'naming the index the server reported' );
ok(
    $conflict->on('notifications_2026_10_pkey'),
    'it is a conflict on the index it names'
);
ok( !$conflict->on('notifications_2026_10'), 'not on a shorter name' );
ok( !$conflict->on('notifications_pkey'),
    'nor, without a catalog to ask, on the parent constraint' );
ok( !$conflict->on(undef), 'nor on no constraint' );
ok(
    !defined GPForum::X::Conflict->from_error($SPOOFED),
    'parameter values saying "unique constraint" make no conflict'
);
ok( !defined GPForum::X::Conflict->from_error(undef), 'nor does no error' );
is( GPForum::X::Conflict->from_error($conflict),
    $conflict, 'a conflict is already one' );

# With a PostgreSQL catalog, a partition's index is a conflict on the parent.
my $catalog = GPForum::Test::ConflictCatalogSchema->new(
    family => [qw(notifications_pkey notifications_2026_10_pkey)] );
my $partitioned = GPForum::X::Conflict->from_error( $DBI_CONFLICT, $catalog );
ok( $partitioned->on('notifications_pkey'),
    'a partition index conflict is a conflict on the parent constraint' );
ok( !$partitioned->on('users_pkey'), 'and on no other' );

# UniqueConflict produces them, and its string consumers keep working.
my $unique = 'GPForum::Infrastructure::UniqueConflict';
my ( $value, $error ) =
  $unique->attempt( undef, sub { die "$DBI_CONFLICT\n" } );
ok( GPForum::X::Conflict->caught($error), 'attempt returns an X::Conflict' );
is( "$error", "$DBI_CONFLICT\n", 'that stringifies to the DBI text' );
ok( index( $error, 'notifications_2026_10_pkey' ) >= 0,
    'index() still finds the constraint' );
ok( $unique->is_conflict($error), 'is_conflict still reads it' );
ok( $unique->is_conflict_on( undef, $error, 'notifications_2026_10_pkey' ),
    'is_conflict_on still reads it' );

my ( undef, $other ) =
  $unique->attempt( undef, sub { die "deadlock detected\n" } );
is( $other, "deadlock detected\n", 'any other error comes back as it was' );
my ( $ok_value, $none ) = $unique->attempt( undef, sub { return 'row' } );
is( $ok_value, 'row', 'a successful attempt returns its value' );
ok( !$none, 'and no error' );

my $fake = _error_of( sub { $unique->throw('posts_pkey') } );
ok( GPForum::X::Conflict->caught($fake), 'throw raises an X::Conflict' );
is(
    "$fake",
    'duplicate key value violates unique constraint "posts_pkey" (23505)',
    'with the text the fake stores raised before'
);
is( $fake->constraint, 'posts_pkey', 'naming the constraint' );
ok( $fake->on('posts_pkey'), 'which it is a conflict on' );

my $rethrown = _error_of( sub { $unique->rethrow($fake) } );
is( $rethrown, $fake, 'rethrow passes the exception through unchanged' );

done_testing();

# What the code died with; undef when it did not.
sub _error_of ($code) {
    if ( eval { $code->(); 1 } ) {
        return undef;
    }

    return $EVAL_ERROR;
}

1;
