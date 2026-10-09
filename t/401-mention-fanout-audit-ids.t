# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;
use utf8;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Community::MentionStore;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::RecordingAuditRecorder;
use GPForum::Test::Schema;

our $VERSION = '0.001';

const my $MENTIONED        => 3;
const my $MAX_MENTIONS     => 1;
const my $ACTOR            => '0f8e2b1c-6d3a-4f5e-9a7b-1c2d3e4f5a6b';
const my $SOURCE           => '1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d';
const my $FULLWIDTH_OFFSET => 0xFEE0;    # U+0030 + this is U+FF10

# The fan-out audit's actor_id and target_id are uuid columns, so a value
# that is not a uuid is written as undef rather than failing the insert. A
# uuid's shape is Infrastructure::Id's: its fullwidth digits (U+FF10...) are
# not ASCII hex digits, PostgreSQL's uuid input rejects them, and the
# store's own pattern, which matched them, lost the audit row to them.
my @users = map {
    {
        deleted_at => undef,
        id         => "user-$_",
        username   => sprintf( 'user%03d', $_ ),
    }
} 1 .. $MENTIONED;

for my $case (
    [ $ACTOR,    $SOURCE,  $ACTOR, $SOURCE, 'uuids are kept' ],
    [ 'actor-1', 'post-1', undef,  undef,   'other ids are written as undef' ],
    [
        _fullwidth($ACTOR), _fullwidth($SOURCE), undef, undef,
        'uuids in fullwidth digits are written as undef'
    ],
  )
{
    my ( $actor_id, $source_id, $audited_actor, $audited_target, $name ) =
      @{$case};
    my $recorder = GPForum::Test::RecordingAuditRecorder->new;
    my $store    = GPForum::Service::Community::MentionStore->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
        recorder   => $recorder,
        schema     => GPForum::Test::Schema->new( users => \@users ),
    );
    $store->record_for_source(
        {
            actor_id     => $actor_id,
            body_source  => join( q{ }, map { "\@$_->{username}" } @users ),
            max_mentions => $MAX_MENTIONS,
            source_id    => $source_id,
            source_type  => 'post',
            thread_id    => 'thread-1',
        }
    );

    my ($audit) =
      grep { $_->{action} eq 'mention.fanout_limited' } @{ $recorder->audits };
    ok( $audit, "$name: the fan-out is audited" );
    is( $audit->{actor_id},  $audited_actor,  "$name: actor_id" );
    is( $audit->{target_id}, $audited_target, "$name: target_id" );
}

done_testing();

# The same uuid with its ASCII digits and letters in their fullwidth forms.
sub _fullwidth ($uuid) {
    return join q{},
      map { /[[:xdigit:]]/msxa ? chr( ord() + $FULLWIDTH_OFFSET ) : $_ }
      split //msx, $uuid;
}

1;
