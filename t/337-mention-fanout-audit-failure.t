# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Community::MentionStore;
use GPForum::Test::FailingAuditRecorder;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::Schema;

our $VERSION = '0.001';

const my $MENTIONED    => 8;
const my $MAX_MENTIONS => 3;

# The fan-out audit says that a post mentioned more members than are
# notified. It is a note, not part of the mention: when it cannot be
# written, the mentions within the limit are still recorded and nothing
# dies.
my @users = map {
    {
        deleted_at => undef,
        id         => "user-$_",
        username   => sprintf( 'user%03d', $_ ),
    }
} 1 .. $MENTIONED;
my $schema = GPForum::Test::Schema->new( users => \@users );
my $store  = GPForum::Service::Community::MentionStore->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    recorder   => GPForum::Test::FailingAuditRecorder->new,
    schema     => $schema,
);

my ( $result, $error );
try {
    $result = $store->record_for_source(
        {
            actor_id     => 'actor-1',
            body_source  => join( q{ }, map { "\@$_->{username}" } @users ),
            max_mentions => $MAX_MENTIONS,
            source_id    => 'post-1',
            source_type  => 'post',
            thread_id    => 'thread-1',
        }
    );
}
catch ($caught) {
    $error = $caught;
};

ok( !defined $error, 'a fan-out audit that fails does not fail the mentions' );
is( scalar @{ $result->{created} },
    $MAX_MENTIONS, 'the mentions within the limit are recorded' );
is(
    scalar( grep { $_->{reason} eq 'fanout_limited' } @{ $result->{skipped} } ),
    $MENTIONED - $MAX_MENTIONS,
    'and the rest are skipped for the limit'
);

done_testing();

1;
