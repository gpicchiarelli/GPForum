package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Service::Attachment::Event;
use GPForum::Test::Id;
use Test::More;

our $VERSION = '0.001';

const my $SCHEMA_VERSION => 1;

my $events = GPForum::Service::Attachment::Event->new(
    id_service => GPForum::Test::Id->new, );

is( $events->scan_event_type('clean'),
    'attachment.scanned', 'scan_event_type maps a clean scan' );
is( $events->scan_event_type('infected'),
    'attachment.quarantined', 'scan_event_type maps any other scan' );

my $intent = {
    attachment_id => 'att-1',
    byte_size     => 1,
    media_type    => 'image/png',
    object_key    => 'objects/att-1',
    owner_user_id => 'user-1',
};
is_deeply(
    $events->uploaded_payload($intent),
    {
        attachment_id => 'att-1',
        byte_size     => 1,
        media_type    => 'image/png',
        object_key    => 'objects/att-1',
        owner_user_id => 'user-1',
    },
    'uploaded_payload keeps intent fields'
);

my $scan = {
    attachment_id => 'att-1',
    reason        => 'ok',
    scan_status   => 'clean',
};
is_deeply( $events->scan_payload($scan),
    $scan, 'scan_payload keeps scan fields' );
is_deeply(
    $events->deleted_payload( { attachment_id => 'att-1', reason => 'gone' } ),
    { attachment_id => 'att-1', reason => 'gone' },
    'deleted_payload keeps delete fields'
);

my $envelope = $events->envelope(
    {
        actor_id       => 'user-1',
        attachment_id  => 'att-1',
        correlation_id => 'corr-1',
        event_type     => 'attachment.uploaded',
        payload        => $events->uploaded_payload($intent),
    }
);
is( $envelope->{event_id}, 'generated-1', 'envelope allocates an event id' );
is( $envelope->{aggregate_type},
    'attachment', 'envelope uses the attachment aggregate' );
is( $envelope->{schema_version},
    $SCHEMA_VERSION, 'envelope uses schema version 1' );
is( $envelope->{idempotency_key},
    'attachment.uploaded:att-1',
    'envelope keys idempotency on type and attachment' );
is_deeply(
    $envelope->{payload},
    $events->uploaded_payload($intent),
    'envelope keeps the supplied payload'
);

is_deeply(
    $events->audit( 'attachment.uploaded', $intent, 'corr-1' ),
    {
        action         => 'attachment.uploaded',
        actor_id       => 'user-1',
        correlation_id => 'corr-1',
        metadata       => { object_key => 'objects/att-1' },
        schema_version => $SCHEMA_VERSION,
        target_id      => 'att-1',
        target_type    => 'attachment',
    },
    'audit keeps object_key metadata and owner actor'
);

done_testing();

1;
