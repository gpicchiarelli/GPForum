# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::Row;
use GPForum::Test::RowDouble;
use GPForum::Infrastructure::UniqueConflict;

our $VERSION = '0.001';

const my $HASH_SCORE  => 7;
const my $ROW_SCORE   => 9;
const my $LIST_LENGTH => 6;
const my $KEPT_KEYS   => 3;

my $reader = 'GPForum::Infrastructure::Row';

is( $reader->column( { score => $HASH_SCORE }, 'score' ),
    $HASH_SCORE, 'reads a hashref column' );
is( $reader->column( { score => $HASH_SCORE }, 'missing' ),
    undef, 'a missing hashref key is undef' );

is(
    $reader->column(
        GPForum::Test::RowDouble->new( columns => { score => $ROW_SCORE } ),
        'score'
    ),
    $ROW_SCORE,
    'reads a resultset row through get_column'
);

is( $reader->column( undef, 'score' ), undef, 'a missing row is undef' );
is( $reader->column( bless( {}, 'GPForum::Test::Opaque' ), 'score' ),
    undef, 'a row that answers neither shape is undef' );

# The defect this reader exists to remove. Forty-one hand-copied versions of
# it disagreed on the last line, and six ended in a bare `return;`. In list
# context that is the empty LIST, not undef, and every one of those six was
# called from inside a hash literal. With a row that was not found the pairs
# collapse and every following key shifts by one.
# Proof the assertion below is not vacuous: this is the old body, and it
# corrupts the same hash.
sub _old_column {
    my ( $row, $name ) = @_;
    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row && $row->can('get_column');
    return;
}

# The corruption Perl reports only as "Odd number of elements"; silenced here
# because provoking it is the point of this block.
no warnings 'misc';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
my %corrupted = (
    calculated_at => _old_column( undef, 'calculated_at' ),
    score         => _old_column( undef, 'score' ),
    trust_level   => _old_column( undef, 'trust_level' ),
);
is( $corrupted{calculated_at},
    'score',
    'the old bare-return body shifted calculated_at onto the next key' );
isnt( scalar keys %corrupted,
    $KEPT_KEYS, 'the old body did not even keep three keys' );
use warnings 'misc';

my @context = (
    calculated_at => $reader->column( undef, 'calculated_at' ),
    score         => $reader->column( undef, 'score' ),
    trust_level   => $reader->column( undef, 'trust_level' ),
);
is( scalar @context,
    $LIST_LENGTH, 'each lookup yields exactly one list element' );

my %public = @context;
is( scalar keys %public, $KEPT_KEYS, 'the hash keeps all three keys' );
ok( exists $public{score}, 'score survives as a key' );
is( $public{calculated_at}, undef,
    'calculated_at holds undef, not the name of the next key' );

# --- unique-conflict classification -------------------------------------
# is_conflict used to match the five digits of SQLSTATE 23505 anywhere in the
# error text, and the recovery path swallows whatever it classifies: an
# unrelated failure mentioning those digits in an offset or an id was accepted
# as a duplicate-key replay and its real error discarded.
my $conflict = 'GPForum::Infrastructure::UniqueConflict';
ok( $conflict->is_conflict('... unique constraint "x" (23505)'),
    'a real SQLSTATE 23505 is a conflict' );
ok( $conflict->is_conflict('duplicate key value violates unique constraint'),
    'the English server text is still recognised' );
ok(
    !$conflict->is_conflict('deadlock detected at byte offset 123505'),
    'digits embedded in a larger number are not a conflict'
);
ok(
    !$conflict->is_conflict('could not read row 235051'),
    'a longer number starting with the sqlstate is not a conflict'
);
ok( !$conflict->is_conflict('connection reset by peer'),
    'an unrelated error is not a conflict' );

done_testing();

1;
