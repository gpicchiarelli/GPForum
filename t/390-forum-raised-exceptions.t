# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Domain::EventEnvelope;
use GPForum::Service::Forum::ReadState;
use GPForum::X::Argument;

our $VERSION = '0.001';

# The forum services and the domain envelope raise GPForum::X::Argument when
# a caller breaks their contract (ADR 0118), with the message they raised as
# a string before.

my $envelope = GPForum::Domain::EventEnvelope->new;

my %complete = (
    aggregate_id   => 'thread-1',
    aggregate_type => 'thread',
    correlation_id => 'correlation-1',
    event_id       => 'event-1',
    event_type     => 'thread.created',
);

for my $field (qw(event_id event_type aggregate_type correlation_id)) {
    my %input = ( %complete, $field => q{} );
    my $error = _error_of( sub { $envelope->record(%input) } );
    ok( GPForum::X::Argument->caught($error),
        "an envelope without $field is an argument error" );
    is( "$error", "$field is required", "naming $field" );
}

my $keyless = _error_of(
    sub { $envelope->idempotency_key( event_type => 'thread.created' ) } );
ok( GPForum::X::Argument->caught($keyless),
    'an idempotency key without an aggregate is an argument error' );
is( "$keyless", 'aggregate_id is required', 'naming aggregate_id' );

my $unused_schema = bless {}, 'GPForum::Test::UnusedSchema';
my $read_state =
  GPForum::Service::Forum::ReadState->new( schema => $unused_schema );
my $opaque = bless {}, 'GPForum::Test::OpaqueRow';
my $columnless =
  _error_of( sub { $read_state->summary_for_page( undef, 't1', [$opaque] ) } );
ok(
    GPForum::X::Argument->caught($columnless),
    'a post with no columns is an argument error'
);
is(
    "$columnless",
    'read state row does not expose columns',
    'with the message it raised before'
);

done_testing;

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
