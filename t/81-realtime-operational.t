package main;

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Realtime::ChannelAuthorizer;
use GPForum::Service::Realtime::ConnectionRegistry;
use GPForum::Service::Realtime::EventEnvelope;
use GPForum::Service::Realtime::Hub;
use GPForum::Service::Realtime::PgListener;
use GPForum::Service::Realtime::PgNotifier;
use GPForum::Service::Realtime::SubscriptionPolicy;
use GPForum::Test::RealtimeConnection;
use GPForum::Test::RealtimePermissionEngine;

our $VERSION = '0.001';

my $contract = GPForum::Service::Realtime::EventEnvelope->new(
    clock             => GPForum::Test::RealtimeClock->new,
    id_service        => GPForum::Test::RealtimeId->new,
    max_payload_bytes => 512,
);
my $event = $contract->build(
    type           => 'thread.update',
    aggregate_type => 'thread',
    aggregate_id   => 'thread-1',
    actor_id       => 'user-1',
    payload        => { post_id => 'post-1' },
);

is( $event->{schema_version}, 1, 'realtime event defaults schema version' );
is( $event->{occurred_at},
    '2026-05-28T12:00:00Z', 'realtime event has occurred timestamp' );
is( $event->{type}, 'thread.update', 'realtime event has type' );

my $serialized = $contract->serialize($event);
ok( $serialized->{ok},        'realtime event serializes' );
ok( $serialized->{bytes} > 0, 'realtime event reports serialized size' );
ok(
    !$contract->deserialize('{bad-json')->{ok},
    'realtime event rejects malformed JSON'
);
ok(
    !$contract->serialize(
        $contract->build(
            type           => 'thread.update',
            aggregate_type => 'thread',
            aggregate_id   => 'thread-1',
            payload        => { body => 'x' x 600 },
        )
    )->{ok},
    'realtime event rejects oversized payloads'
);

my $policy_schema = GPForum::Test::RealtimePolicySchema->new(
    categories => {
        'category-1' => {
            category_id => 'category-1',
            visibility  => 'public',
        },
        'category-private' => {
            category_id => 'category-private',
            visibility  => 'private',
        },
    },
    resource_acls => {
        'thread:thread-acl:user-1' => 1,
    },
    threads => {
        'thread-1' => {
            author_user_id   => 'author-1',
            category_id      => 'category-1',
            moderation_state => 'visible',
            thread_id        => 'thread-1',
            visibility       => 'public',
        },
        'thread-hidden' => {
            author_user_id   => 'author-1',
            category_id      => 'category-1',
            moderation_state => 'hidden',
            thread_id        => 'thread-hidden',
            visibility       => 'public',
        },
        'thread-acl' => {
            author_user_id   => 'author-1',
            category_id      => 'category-private',
            moderation_state => 'visible',
            thread_id        => 'thread-acl',
            visibility       => 'private',
        },
    },
    users => {
        'user-1'         => { id => 'user-1',         status => 'active' },
        'user-suspended' => { id => 'user-suspended', status => 'suspended' },
    },
);
my $policy =
  GPForum::Service::Realtime::SubscriptionPolicy->new( schema => $policy_schema,
  );

ok(
    $policy->can(
        { user_id => 'user-1' }, 'realtime.subscribe',
        { type    => 'thread', id => 'thread-1' }, {},
    )->{ok},
    'subscription policy allows visible public thread'
);
is(
    $policy->can(
        { user_id => 'user-1' }, 'realtime.subscribe',
        { type    => 'thread', id => 'thread-hidden' }, {},
    )->{reason},
    'invisible_resource',
    'subscription policy denies hidden thread'
);
is(
    $policy->can(
        { user_id => 'user-suspended' }, 'realtime.subscribe',
        { type    => 'thread', id => 'thread-1' }, {},
    )->{reason},
    'forbidden',
    'subscription policy denies suspended users'
);
ok(
    $policy->can(
        { user_id => 'user-1' }, 'realtime.subscribe',
        { type    => 'thread', id => 'thread-acl' }, {},
    )->{ok},
    'subscription policy allows explicit resource ACL'
);

my $dbh      = GPForum::Test::RealtimePgDbh->new;
my $schema   = GPForum::Test::RealtimePgSchema->new( dbh => $dbh );
my $notifier = GPForum::Service::Realtime::PgNotifier->new(
    event_contract => $contract,
    schema         => $schema,
);
my $notify = $notifier->notify($event);
ok( $notify->{ok}, 'PostgreSQL notifier emits realtime event' );
like( $dbh->statements->[0][0],
    qr/pg_notify/msx, 'PostgreSQL notifier uses pg_notify' );

my $degraded_notify =
  GPForum::Service::Realtime::PgNotifier->new( event_contract => $contract )
  ->notify($event);
ok( !$degraded_notify->{ok}, 'notifier degrades when DB is unavailable' );
is( $degraded_notify->{failure_type},
    'transport', 'notifier degraded failure is classified as transport' );

my $hub = GPForum::Service::Realtime::Hub->new(
    event_contract => $contract,
    registry       => GPForum::Service::Realtime::ConnectionRegistry->new,
    authorizer     => GPForum::Service::Realtime::ChannelAuthorizer->new(
        permission_engine => GPForum::Test::RealtimePermissionEngine->new,
    ),
);
my $connection = GPForum::Test::RealtimeConnection->new;
$hub->register_connection( 'connection-1', { user_id => 'user-1' },
    $connection );
$hub->subscribe(
    {
        actor         => { user_id => 'user-1' },
        channel       => 'thread:thread-1',
        connection_id => 'connection-1',
        context       => {},
    }
);

my $listener_dbh = GPForum::Test::RealtimePgDbh->new(
    notifies => [
        [ 'gpforum_realtime_events', 1, $serialized->{json} ],
        [ 'gpforum_realtime_events', 1, $serialized->{json} ],
        [ 'gpforum_realtime_events', 1, '{bad-json' ],
    ],
);
my $listener = GPForum::Service::Realtime::PgListener->new(
    event_contract => $contract,
    hub            => $hub,
    schema => GPForum::Test::RealtimePgSchema->new( dbh => $listener_dbh ),
);
ok( $listener->start->{ok}, 'PostgreSQL listener starts LISTEN lifecycle' );
my $poll = $listener->poll_once;
is( $poll->{received},   3, 'listener receives queued notifications' );
is( $poll->{delivered},  1, 'listener fans out valid event once' );
is( $poll->{duplicates}, 1, 'listener suppresses duplicate event ids' );
is( $poll->{invalid},    1, 'listener rejects malformed payload' );
is( scalar @{ $connection->sent }, 1, 'websocket receives one event' );

$listener->reconnect;
is( $listener->snapshot->{reconnect_count},
    1, 'listener records reconnect count' );

my $degraded_listener = GPForum::Service::Realtime::PgListener->new;
ok( !$degraded_listener->start->{ok},
    'listener degrades when DB is unavailable' );
is( $degraded_listener->snapshot->{status},
    'degraded', 'listener exposes degraded status' );

done_testing();

package GPForum::Test::RealtimeClock;

sub new {
    my ($class) = @_;

    return bless {}, $class;
}

sub now_iso8601 {
    return '2026-05-28T12:00:00Z';
}

package GPForum::Test::RealtimeId;

sub new {
    my ($class) = @_;

    return bless {}, $class;
}

sub uuid {
    return 'event-1';
}

package GPForum::Test::RealtimePolicySchema;

sub new {
    my ( $class, %input ) = @_;

    return bless {
        categories    => $input{categories}    || {},
        resource_acls => $input{resource_acls} || {},
        threads       => $input{threads}       || {},
        users         => $input{users}         || {},
    }, $class;
}

sub categories {
    my ($self) = @_;

    return $self->{categories};
}

sub resource_acls {
    my ($self) = @_;

    return $self->{resource_acls};
}

sub threads {
    my ($self) = @_;

    return $self->{threads};
}

sub users {
    my ($self) = @_;

    return $self->{users};
}

sub resultset {
    my ( $self, $name ) = @_;

    return GPForum::Test::RealtimePolicyResultSet->new(
        name   => $name,
        schema => $self,
    );
}

package GPForum::Test::RealtimePolicyResultSet;

sub new {
    my ( $class, %input ) = @_;

    return bless { name => $input{name}, schema => $input{schema} }, $class;
}

sub name {
    my ($self) = @_;

    return $self->{name};
}

sub schema {
    my ($self) = @_;

    return $self->{schema};
}

sub find {
    my ( $self, $id ) = @_;

    my %collection_for = (
        Category => 'categories',
        Thread   => 'threads',
        User     => 'users',
    );
    my $collection = $collection_for{ $self->name };
    return if !$collection;

    my $rows = $self->schema->$collection;
    my $row  = $rows->{$id};
    return if !$row;

    return GPForum::Test::RealtimePolicyRow->new( data => $row );
}

sub search {
    my ( $self, $query ) = @_;

    my $key = join q{:},
      $query->{resource_type},
      $query->{resource_id},
      $query->{user_id};

    return GPForum::Test::RealtimePolicySearch->new(
        found => $self->schema->resource_acls->{$key} ? 1 : 0 );
}

package GPForum::Test::RealtimePolicyRow;

sub new {
    my ( $class, %input ) = @_;

    return bless { data => $input{data} || {} }, $class;
}

sub data {
    my ($self) = @_;

    return $self->{data};
}

sub get_column {
    my ( $self, $column ) = @_;

    return $self->data->{$column};
}

package GPForum::Test::RealtimePolicySearch;

sub new {
    my ( $class, %input ) = @_;

    return bless { found => $input{found} || 0 }, $class;
}

sub found {
    my ($self) = @_;

    return $self->{found};
}

sub single {
    my ($self) = @_;

    return $self->found ? GPForum::Test::RealtimePolicyRow->new : undef;
}

package GPForum::Test::RealtimePgSchema;

sub new {
    my ( $class, %input ) = @_;

    return bless { dbh => $input{dbh} }, $class;
}

sub dbh {
    my ($self) = @_;

    return $self->{dbh};
}

sub storage {
    my ($self) = @_;

    return GPForum::Test::RealtimePgStorage->new( dbh => $self->dbh );
}

package GPForum::Test::RealtimePgStorage;

sub new {
    my ( $class, %input ) = @_;

    return bless { dbh => $input{dbh} }, $class;
}

sub dbh {
    my ($self) = @_;

    return $self->{dbh};
}

package GPForum::Test::RealtimePgDbh;

sub new {
    my ( $class, %input ) = @_;

    return bless {
        notifies   => $input{notifies}   || [],
        statements => $input{statements} || [],
    }, $class;
}

sub notifies {
    my ($self) = @_;

    return $self->{notifies};
}

sub statements {
    my ($self) = @_;

    return $self->{statements};
}

sub do {
    my ( $self, @arguments ) = @_;

    push @{ $self->statements }, \@arguments;

    return 1;
}

sub pg_notifies {
    my ($self) = @_;

    return shift @{ $self->notifies };
}

1;
