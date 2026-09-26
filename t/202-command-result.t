# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Operations::CommandIdempotency;
use GPForum::Test::Schema;

our $VERSION = '0.001';

# CommandIdempotency::result_of answers a workflow command in the shape every
# workflow returns (ADR 0110): seven workflows had their own copy of this.
my $idempotency = GPForum::Service::Operations::CommandIdempotency->new(
    schema => GPForum::Test::Schema->new );
my $runs = 0;
my %job  = (
    actor_id     => 'user-1',
    command_id   => ' command-1 ',
    command_type => 'test.command',
    request      => { title => 'first' },
    run          => sub {
        $runs++;
        return { ok => 1, status => 'ok', stored => { id => 'row-1' } };
    },
);

is_deeply(
    $idempotency->result_of( { %job, command_id => q{ } } ),
    {
        error  => undef,
        errors => { command_id => 'command_id is required' },
        ok     => 0,
        status => 'invalid',
        stored => undef,
    },
    'a command without an id is invalid'
);
is( $runs, 0, 'and never runs' );

my $first = $idempotency->result_of( {%job} );
is( $first->{status}, 'ok', 'a new command runs and returns its result' );
is( $runs,            1,    'once' );

is_deeply( $idempotency->result_of( {%job} ),
    $first, 'repeating it replays the stored answer' );
is( $runs, 1, 'without running it again' );

my $conflict =
  $idempotency->result_of( { %job, request => { title => 'second' } } );
is( $conflict->{status}, 'conflict',
    'the same id for another request is a conflict' );
ok( !$conflict->{ok}, 'and not ok' );

done_testing();

1;
