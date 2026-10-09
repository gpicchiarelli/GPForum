# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::OutboxMessageBuilder;
use GPForum::Test::Id;
use GPForum::Test::Schema;
use Test::More;

our $VERSION = '0.001';

ok(
    !exists $INC{'GPForum/Service/Id.pm'},
    'Id stays unloaded when the recorder compiles'
);

my $builder = GPForum::Infrastructure::OutboxMessageBuilder->new(
    id_service => GPForum::Test::Id->new, );
my $message = $builder->for_event(
    {
        actor_id          => 'user-1',
        aggregate_id      => 'post-1',
        aggregate_type    => 'post',
        aggregate_version => 1,
        correlation_id    => 'correlation-1',
        event_id          => 'event-1',
        event_type        => 'post.created',
        idempotency_key   => 'post.created:post-1',
        metadata          => {},
        payload           => { thread_id => 'thread-1' },
        schema_version    => 1,
    }
);

is( $message->{outbox_id}, 'generated-1',
    'injected id_service supplies the outbox id' );
is( $message->{queue}, 'events', 'outbox queue stays events' );
ok( !exists $INC{'GPForum/Service/Id.pm'},
    'Id stays unloaded after an injected builder write' );

my $recorder = GPForum::Infrastructure::EventRecorder->new(
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::Schema->new,
);
ok( $recorder, 'an injected recorder constructs without Id' );
ok( !exists $INC{'GPForum/Service/Id.pm'},
    'Id stays unloaded after an injected recorder construct' );

my $unwired;
try {
    GPForum::Infrastructure::EventRecorder->new(
        id_service => GPForum::Test::Id->new );
}
catch ($error) {
    $unwired = $error;
};
isa_ok( $unwired, 'GPForum::X::Argument', 'a recorder built without a schema' );
like( "$unwired", qr/requires [ ] schema/msx, 'names the missing schema' );

require GPForum::Service::Attachment::Store;
require GPForum::Service::Moderation::ActionStore;
require GPForum::Service::Admin::RoleCatalog;
require GPForum::Service::Admin::CategoryStore;
require GPForum::Service::Privacy::DeletionWorkflow;
require GPForum::Service::Forum::PostStore;
ok(
    !exists $INC{'GPForum/Service/Id.pm'},
    'event-backed stores compile without Id'
);

done_testing();

1;
