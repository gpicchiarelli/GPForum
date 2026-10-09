# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Test::Schema;

our $VERSION = '0.001';

# The server's sentence as DBIx::Class hands it over, with PostgreSQL's DETAIL
# line and the statement and parameter values DBI appends.
const my $PREFIX => 'DBIx::Class::Storage::DBI::_dbh_execute(): DBI Exception:'
  . ' DBD::Pg::st execute failed: ERROR:  duplicate key value violates'
  . ' unique constraint';
const my $STATEMENT => ' [for Statement "INSERT INTO users ( display_name,'
  . ' id ) VALUES ( ?, ? )" with ParamValues: 1=%s, 2=7]';

# PostgreSQL's program_limit_exceeded (54000) for a key too large to index:
# its first line names the index, and it is no unique violation.
const my $TOO_LARGE => 'DBIx::Class::Storage::DBI::_dbh_execute(): DBI'
  . ' Exception: DBD::Pg::st execute failed: ERROR:  index row size 3072'
  . ' exceeds btree version 4 maximum 2704 for index "users_pkey"'
  . "\nDETAIL:  Index row references tuple (0,1) in relation \"users\".";

# A constraint quoted as German messages quote it.
const my $GUILLEMETS => "\N{RIGHT-POINTING DOUBLE ANGLE QUOTATION MARK}"
  . 'users_pkey'
  . "\N{LEFT-POINTING DOUBLE ANGLE QUOTATION MARK}";

my $conflict = 'GPForum::Infrastructure::UniqueConflict';

# is_conflict_on: a unique violation of one constraint and no other. Without
# a PostgreSQL handle there is no catalog to ask for a partitioned table's
# partition indexes, and only the constraint's own name is matched -- the
# fake ORM raises that name. postgres-partition-conflicts.t covers the
# catalog.
ok( $conflict->is_conflict_on( undef, _conflict('users_pkey'), 'users_pkey' ),
    'a conflict naming the constraint is a conflict on it' );
ok(
    !$conflict->is_conflict_on(
        undef, _conflict('users_username_key'), 'users_pkey'
    ),
    'a conflict naming another constraint is not'
);
ok(
    !$conflict->is_conflict_on(
        undef, 'deadlock detected on users_pkey', 'users_pkey'
    ),
    'an error that is no unique violation is not, whatever it names'
);
ok(
    !$conflict->is_conflict_on( undef, _conflict('users_pkey'), q{} ),
    'nor is anything a conflict on a constraint with no name'
);

my $raised;
try {
    $conflict->throw('notifications_pkey');
}
catch ($error) {
    $raised = $error;
};
ok(
    $conflict->is_conflict_on( undef, $raised, 'notifications_pkey' ),
    'the fake ORM conflict, raised with croak, is one on its constraint'
);

# A whole identifier: index() found notifications_pkey inside any longer name
# that contains it.
ok(
    !$conflict->is_conflict_on(
        undef, _conflict('thread_posts_pkey'), 'posts_pkey'
    ),
    'a constraint is not named by a longer name ending in it'
);
ok(
    !$conflict->is_conflict_on(
        undef, _conflict('notifications_pkey_old'),
        'notifications_pkey'
    ),
    'nor by a longer name starting with it'
);
ok( $conflict->is_conflict_on( undef, "$PREFIX $GUILLEMETS", 'users_pkey' ),
    'however the message quotes it' );

# The DETAIL line and the parameter values are the row's data: a member's
# display name is not the server naming a constraint.
my $in_detail = _conflict('users_username_key')
  . "\nDETAIL:  Key (username)=(users_pkey) already exists.";
ok(
    !$conflict->is_conflict_on( undef, $in_detail, 'users_pkey' ),
    'a constraint spelled in the DETAIL line is not the one violated'
);
my $in_values = _conflict('users_username_key') . sprintf $STATEMENT,
  q{'users_pkey'};
ok(
    !$conflict->is_conflict_on( undef, $in_values, 'users_pkey' ),
    'nor one spelled in the parameter values on the same line'
);
ok(
    $conflict->is_conflict_on(
        undef, _conflict('users_pkey') . sprintf( $STATEMENT, q{'x'} ),
        'users_pkey'
    ),
    'while the server sentence before them still names its own'
);

# Nor is the data what says the error is a unique violation: is_conflict
# reads the whole text, and an index row too large for its index names that
# index on an error that is no conflict.
my $too_large = $TOO_LARGE . sprintf $STATEMENT,
  q{'duplicate key value violates unique constraint'};
ok( $conflict->is_conflict($too_large),
    'an error whose values spell a unique violation reads as one as a whole' );
ok(
    !$conflict->is_conflict_on( undef, $too_large, 'users_pkey' ),
    'but is no conflict on the index its server sentence names'
);

# A test double's schema has a storage and a handle, but no PostgreSQL to
# ask: its conflict is matched on the name alone, and asking does not die.
my $double = GPForum::Test::Schema->new;
ok(
    $conflict->is_conflict_on(
        $double, _conflict('notifications_pkey'),
        'notifications_pkey'
    ),
    q{a double's conflict on the constraint is recognised}
);
ok(
    !$conflict->is_conflict_on(
        $double, _conflict('notifications_default_pkey'),
        'notifications_pkey'
    ),
    q{and without a catalog a partition's index is not taken for it}
);

done_testing();

sub _conflict {
    my ($name) = @_;

    return qq{$PREFIX "$name"};
}

1;
