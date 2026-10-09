# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::ReadState;
use GPForum::Test::CountingReadStateResultSet;
use GPForum::Test::FixedClock;
use GPForum::Test::ReadStateResultSet;
use GPForum::Test::ReadStateSchema;
use GPForum::X::Conflict;

our $VERSION = '0.001';

# The paths of ReadState that t/41 leaves unpinned: a first mark that does
# not move the position, a negative position or missing ids, the anonymous
# summary, a thread nobody names, an existing marker moved forward, a
# concurrent first mark behind this one, and errors that are not a marker
# someone else wrote: unique violations on a constraint that is not the
# marker's or the delta's own key, and a database error.

const my $STORED_POSITION  => 1;
const my $AHEAD_POSITION   => 2;
const my $BEHIND_POSITION  => 1;
const my $NO_POSITION      => 0;
const my $NEGATIVE         => -1;
const my $OWN_MISS         => 1;
const my $OWN_AND_RELOAD   => 2;
const my $STORED_AT        => '2026-01-01T00:00:00Z';
const my $FOREIGN_KEY_NAME => 'thread_read_state_other_key';

plan tests => 21;

my %stored = (
    last_read_at       => $STORED_AT,
    last_read_position => $STORED_POSITION,
    thread_id          => 't1',
    user_id            => 'u1',
);

{
    my $fixture = _fixture();
    my $marked  = _mark( $fixture, $NO_POSITION );
    ok(
        $marked->{ok} && !$marked->{skipped},
        'a first mark at position 0 writes the marker'
    );
    is( $marked->{advanced}, 0,
        'and says it did not advance, the position being where it was' );
    is( scalar @{ $fixture->{delta}->created }, 1, 'with its delta row' );
}

{
    my $refused = _mark( _fixture(), $NEGATIVE );
    is_deeply(
        $refused,
        {
            errors => {
                last_read_position =>
                  'last_read_position must be a non-negative integer',
            },
            ok     => 0,
            status => 'invalid',
        },
        'a negative position is refused as invalid'
    );
}

is_deeply(
    _fixture()->{read_state}->mark_thread_read( {} )->{errors},
    {
        last_read_position =>
          'last_read_position must be a non-negative integer',
        thread_id => 'thread_id is required',
        user_id   => 'user_id is required',
    },
    'a mark without its ids or position names each field'
);

is_deeply(
    GPForum::Service::Forum::ReadState->new(
        schema => bless {},
        'GPForum::Test::UnusedSchema'
    )->state_for_thread( 'u1', q{} ),
    {
        last_read_at       => undef,
        last_read_position => $NO_POSITION,
        thread_id          => q{},
        user_id            => 'u1',
    },
    'a thread nobody names has the empty state, without a lookup'
);

{
    my $fixture = _fixture( rows => [ {%stored} ] );
    my $marked  = _mark( $fixture, $AHEAD_POSITION );
    ok(
        $marked->{ok} && $marked->{advanced},
        'an existing marker is moved forward'
    );
    is( $fixture->{state}->create_attempts,
        0, 'in place, without trying to insert another' );
    is( $fixture->{delta}->rows->{'u1:t1'}->get_column('last_read_position'),
        $AHEAD_POSITION, 'and its delta carries the new position' );
}

{
    # A concurrent marker is ahead, but this mark's insert failed for
    # another reason: that error is the answer, not a skipped mark.
    my %ahead   = ( %stored, last_read_position => $AHEAD_POSITION );
    my $fixture = _fixture(
        rows    => [ \%ahead ],
        misses  => $OWN_MISS,
        failure => "connection lost\n",
    );
    my $error = _error_of( sub { _mark( $fixture, $BEHIND_POSITION ) } );
    like(
        "$error",
        qr/\Aconnection [ ] lost/msx,
        'a database error on a first mark is rethrown'
    );
}

{
    my $summary = _fixture()->{read_state}
      ->summary_for_page( undef, 't1', [ { post_id => 'p1', position => 1 } ] );
    is( $summary->{unread_in_page}, 0, 'an anonymous reader has no unread' );
    ok(
        !defined $summary->{first_unread_post_id}
          && !defined $summary->{first_unread_anchor},
        'and no first unread post'
    );
}

{
    # The marker is there, but this mark's own lookup ran before it was.
    my $fixture = _fixture( rows => [ {%stored} ], misses => $OWN_MISS );
    my $marked  = _mark( $fixture, $AHEAD_POSITION );
    ok( $marked->{ok} && !$marked->{skipped},
        'a concurrent first mark behind this one is advanced, not skipped' );
    is( $marked->{advanced}, 1, 'past the position it stored' );
    is( $fixture->{state}->rows->{'u1:t1'}->get_column('last_read_position'),
        $AHEAD_POSITION, 'to this mark\'s position' );
    is( scalar @{ $fixture->{state}->created },
        0, 'without inserting another marker' );
}

{
    # The insert collides on another key, and the reload misses too.
    my $fixture = _fixture(
        rows       => [ {%stored} ],
        misses     => $OWN_AND_RELOAD,
        state_name => $FOREIGN_KEY_NAME,
    );
    my $error = _error_of( sub { _mark( $fixture, $STORED_POSITION ) } );
    ok( GPForum::X::Conflict->caught($error),
        'a marker insert colliding on another key is rethrown' );
    ok( $error && $error->on($FOREIGN_KEY_NAME), 'naming that key' );
    is( scalar @{ $fixture->{delta}->created }, 0, 'and writes no delta' );
}

{
    my $fixture = _fixture(
        deltas     => [ {%stored} ],
        delta_name => $FOREIGN_KEY_NAME,
    );
    my $error = _error_of( sub { _mark( $fixture, $STORED_POSITION ) } );
    ok( GPForum::X::Conflict->caught($error),
        'a delta insert colliding on another key is rethrown' );
    is_deeply( $fixture->{state}->rows,
        {}, 'and the marker it went with is rolled back' );
}

sub _fixture (%option) {
    my $state = GPForum::Test::CountingReadStateResultSet->new(
        $option{state_name} ? ( unique_name => $option{state_name} ) : () );
    my $delta =
      GPForum::Test::ReadStateResultSet->new( unique_name => $option{delta_name}
          // 'user_read_marker_deltas_pkey' );
    my $schema = GPForum::Test::ReadStateSchema->new(
        resultsets => {
            ThreadReadState     => $state,
            UserReadMarkerDelta => $delta,
        },
    );
    for my $row ( @{ $option{rows} // [] } ) {
        $state->create($row);
    }
    for my $row ( @{ $option{deltas} // [] } ) {
        $delta->create($row);
    }
    $state->created( [] );
    $delta->created( [] );
    $state->find_misses( $option{misses} // 0 );
    $state->create_attempts(0);
    $state->failure( $option{failure} );

    return {
        delta      => $delta,
        read_state => GPForum::Service::Forum::ReadState->new(
            clock  => GPForum::Test::FixedClock->new,
            schema => $schema,
        ),
        state => $state,
    };
}

sub _mark ( $fixture, $position ) {
    return $fixture->{read_state}->mark_thread_read(
        {
            last_read_position => $position,
            thread_id          => 't1',
            user_id            => 'u1',
        }
    );
}

sub _error_of ($code) {
    try {
        $code->();
    }
    catch ($error) {
        return $error;
    };

    return undef;
}

1;
