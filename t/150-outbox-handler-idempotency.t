package main;

use strict;
use warnings;

use Const::Fast;
use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Outbox::DomainEventTransport;
use GPForum::Service::Outbox::Dispatcher;
use GPForum::Test::CountingNotifier;
use GPForum::Test::EventIdempotencySchema;
use GPForum::Test::IdempotencyStore;
use GPForum::Test::OutboxClock;
use GPForum::Test::OutboxCrashRow;
use GPForum::Test::OutboxCreateResultSet;
use GPForum::Test::OutboxPayloadRow;
use GPForum::Test::OutboxResultSet;
use GPForum::Test::OutboxSchema;
use GPForum::Test::IdentityMailer;
use GPForum::Test::WorkerSink;
use GPForum::Worker::EventIdempotencyStore;
use GPForum::Worker::Handler::AttachmentScanning;
use GPForum::Worker::Handler::CacheInvalidation;
use GPForum::Worker::Handler::FeedProjection;
use GPForum::Worker::Handler::IdentityMail;
use GPForum::Worker::Handler::MediaProcessing;
use GPForum::Worker::Handler::NotificationDispatch;
use GPForum::Worker::Handler::ReputationUpdate;
use GPForum::Worker::Handler::SearchIndexing;
use GPForum::Worker::HandlerIdempotency;
use GPForum::Worker::IdempotentJobRunner;

our $VERSION = '0.001';

const my $POST_HANDLERS       => 5;
const my $SINGLE_HANDLER      => 1;
const my $MAIL_RETRY_SENDS    => 2;
const my $STALE_LOCK_NOW      => '2026-05-23T12:01:00Z';
const my $WORKER_SEARCH_KEY   => 'worker.search:event-1';
const my $WORKER_REALTIME_KEY => 'worker.realtime:event-1';

my $catalog = GPForum::Worker::HandlerIdempotency->new;
is(
    $catalog->key_for(
        GPForum::Worker::Handler::SearchIndexing->new,
        { event_id => 'event-1' }
    ),
    $WORKER_SEARCH_KEY,
    'search handler key is worker.search:{event_id}'
);
is(
    $catalog->key_for(
        GPForum::Worker::Handler::NotificationDispatch->new,
        { event_id => 'event-1' }
    ),
    'worker.notification:event-1',
    'notification handler key is worker.notification:{event_id}'
);
is(
    $catalog->key_for(
        GPForum::Worker::Handler::CacheInvalidation->new,
        { event_id => 'event-1' }
    ),
    'worker.cache:event-1',
    'cache handler key is worker.cache:{event_id}'
);
is(
    $catalog->key_for(
        GPForum::Worker::Handler::AttachmentScanning->new,
        { event_id => 'event-1' }
    ),
    'worker.attachment:event-1',
    'attachment handler key is worker.attachment:{event_id}'
);
is(
    $catalog->key_for(
        GPForum::Worker::Handler::MediaProcessing->new,
        { event_id => 'event-1' }
    ),
    'worker.media:event-1',
    'media handler key is worker.media:{event_id}'
);
is(
    $catalog->key_for(
        GPForum::Worker::Handler::FeedProjection->new,
        { event_id => 'event-1' }
    ),
    'worker.feed:event-1',
    'feed handler key is worker.feed:{event_id}'
);
is(
    $catalog->key_for(
        GPForum::Worker::Handler::ReputationUpdate->new,
        { event_id => 'event-1' }
    ),
    'worker.reputation:event-1',
    'reputation handler key is worker.reputation:{event_id}'
);
is(
    $catalog->key_for(
        GPForum::Worker::Handler::IdentityMail->new,
        { event_id => 'event-1' }
    ),
    q{},
    'identity mail is not skip-wrapped so outbox retry can resend'
);
is( $catalog->realtime_key( { event_id => 'event-1' } ),
    $WORKER_REALTIME_KEY,
    'realtime fallback key is worker.realtime:{event_id}' );
is( $catalog->prefix_for('GPForum::Worker::Unknown'),
    q{}, 'unknown handlers have no catalog prefix' );
is( $catalog->key_for( 'GPForum::Worker::Handler::SearchIndexing', {} ),
    q{}, 'keys require an event id' );

my $schema = GPForum::Test::EventIdempotencySchema->new;
my $store  = GPForum::Worker::EventIdempotencyStore->new(
    clock  => GPForum::Test::OutboxClock->new,
    schema => $schema,
);
$store->begin($WORKER_SEARCH_KEY);
ok(
    !$store->is_done($WORKER_SEARCH_KEY),
    'begin does not persist a worker key'
);
$store->mark_failed( $WORKER_SEARCH_KEY, 'boom' );
ok(
    !$store->is_done($WORKER_SEARCH_KEY),
    'mark_failed does not persist a worker key'
);
$store->mark_done( $WORKER_SEARCH_KEY, { event_id => 'event-1' } );
ok( $store->is_done($WORKER_SEARCH_KEY), 'mark_done inserts the worker key' );
is( $schema->keys->rows->{$WORKER_SEARCH_KEY}{event_id},
    'event-1', 'stored row records the event id' );
$store->mark_done( $WORKER_SEARCH_KEY, { event_id => 'event-1' } );
ok( $store->is_done($WORKER_SEARCH_KEY),
    'duplicate mark_done is absorbed as unique replay' );
$schema->keys->fail_error('disk full');
throws_ok(
    sub {
        $store->mark_done( 'worker.search:event-2', { event_id => 'event-2' } );
    },
    qr/disk [ ] full/msx,
    'non-unique insert failures propagate'
);

my $post_sink    = GPForum::Test::WorkerSink->new;
my $post_runner  = _memory_runner();
my $post_notify  = GPForum::Test::CountingNotifier->new;
my $post_message = _payload_row(
    {
        aggregate_id   => 'post-1',
        aggregate_type => 'post',
        event_id       => 'event-1',
        event_type     => 'post.created',
        thread_id      => 'thread-1',
    }
);
my $post_transport = _transport( $post_sink, $post_runner, $post_notify );
my $first_post     = $post_transport->dispatch($post_message);
ok( $first_post->{ok}, 'first post dispatch succeeds with job runner' );
is( $first_post->{handlers},
    $POST_HANDLERS, 'first post dispatch runs five handlers' );
is( scalar @{ $post_sink->records },
    $POST_HANDLERS, 'first post dispatch records five sink actions' );
is( scalar @{ $post_notify->calls },
    1, 'first post dispatch notifies realtime once' );
my $replay_post = $post_transport->dispatch($post_message);
ok( $replay_post->{ok}, 'replayed post dispatch still succeeds' );
is( _skipped_count( $replay_post->{results} ),
    $POST_HANDLERS, 'replayed post handlers are skipped' );
is( $replay_post->{realtime}{skipped},
    1, 'replayed realtime notify is skipped' );
is( scalar @{ $post_sink->records },
    $POST_HANDLERS, 'replayed post dispatch does not recapture sink actions' );
is( scalar @{ $post_notify->calls },
    1, 'replayed post dispatch does not re-notify realtime' );

my $attachment_sink = GPForum::Test::WorkerSink->new;
my $attachment_transport =
  _transport( $attachment_sink, _memory_runner(), undef );
my $attachment_message = _payload_row(
    {
        aggregate_id   => 'attachment-1',
        aggregate_type => 'attachment',
        event_id       => 'event-4',
        event_type     => 'attachment.uploaded',
    }
);
$attachment_transport->dispatch($attachment_message);
my $attachment_replay = $attachment_transport->dispatch($attachment_message);
is( $attachment_replay->{handlers},
    $SINGLE_HANDLER, 'attachment replay still reports the scanning handler' );
is( _skipped_count( $attachment_replay->{results} ),
    $SINGLE_HANDLER, 'attachment scan replay is skipped' );
is( scalar @{ $attachment_sink->records },
    $SINGLE_HANDLER, 'attachment scan is not captured twice' );

my $media_sink      = GPForum::Test::WorkerSink->new;
my $media_transport = _transport( $media_sink, _memory_runner(), undef );
my $media_message   = _payload_row(
    {
        aggregate_id   => 'attachment-1',
        aggregate_type => 'attachment',
        event_id       => 'event-5',
        event_type     => 'attachment.scanned',
        scan_status    => 'clean',
    }
);
$media_transport->dispatch($media_message);
my $media_replay = $media_transport->dispatch($media_message);
is( _skipped_count( $media_replay->{results} ),
    $SINGLE_HANDLER, 'media process replay is skipped' );
is( scalar @{ $media_sink->records },
    $SINGLE_HANDLER, 'media process is not captured twice' );

my $mail_sink    = GPForum::Test::WorkerSink->new;
my $mail_mailer  = GPForum::Test::IdentityMailer->new;
my $mail_message = _payload_row(
    {
        event_id   => 'event-mail-1',
        event_type => 'identity.mail.requested',
        mail       => {
            kind  => 'password_reset',
            to    => 'member@example.test',
            token => 'raw-reset',
        },
    }
);
my $mail_transport = GPForum::Service::Outbox::DomainEventTransport->new(
    handlers => [
        GPForum::Worker::Handler::IdentityMail->new(
            mailer => $mail_mailer,
            sink   => $mail_sink,
        ),
    ],
    job_runner => _memory_runner(),
);
$mail_transport->dispatch($mail_message);
is( scalar @{ $mail_mailer->sent },
    $SINGLE_HANDLER, 'identity mail dispatch sends once' );
is( $mail_mailer->sent->[0]{token},
    'raw-reset', 'identity mail dispatch keeps the outbox token' );
my $mail_replay = $mail_transport->dispatch($mail_message);
ok( $mail_replay->{ok}, 'identity mail replay still succeeds' );
is( _skipped_count( $mail_replay->{results} ),
    0, 'identity mail replay is not skipped' );
is( scalar @{ $mail_mailer->sent },
    $MAIL_RETRY_SENDS, 'identity mail replay resends from the outbox payload' );
is( $mail_mailer->sent->[1]{token},
    'raw-reset', 'identity mail replay still has the raw token' );
is( scalar @{ $mail_sink->records },
    $MAIL_RETRY_SENDS, 'identity mail replay recaptures delivery' );

my $crash_sink   = GPForum::Test::WorkerSink->new;
my $crash_runner = _memory_runner();
my $crash_row    = GPForum::Test::OutboxCrashRow->new(
    data => {
        outbox_id => 'outbox-crash-1',
        payload   => {
            aggregate_id   => 'post-1',
            aggregate_type => 'post',
            event_id       => 'event-crash-1',
            event_type     => 'post.created',
            thread_id      => 'thread-1',
        },
    },
);
my $crash_clock  = GPForum::Test::OutboxClock->new;
my $crash_schema = GPForum::Test::OutboxSchema->new(
    dead_letter_resultset => GPForum::Test::OutboxCreateResultSet->new,
    outbox_resultset      =>
      GPForum::Test::OutboxResultSet->new( rows => [$crash_row] ),
);
my $crash_dispatcher = GPForum::Service::Outbox::Dispatcher->new(
    clock     => $crash_clock,
    schema    => $crash_schema,
    transport => _transport( $crash_sink, $crash_runner, undef ),
    worker_id => 'worker-crash',
);
throws_ok(
    sub { $crash_dispatcher->dispatch_pending(1); },
    qr/crash [ ] after [ ] dispatch/msx,
    'dispatcher can crash after transport dispatch'
);
is( $crash_row->get_column('status'),
    'running', 'crashed dispatch leaves the outbox row running' );
is( scalar @{ $crash_sink->records },
    $POST_HANDLERS, 'crashed dispatch still ran the handlers once' );
$crash_clock->now($STALE_LOCK_NOW);
my $recovered = $crash_dispatcher->dispatch_pending(1);
is( $recovered->{dispatched},
    1, 'stale lock after crash is reclaimed and dispatched' );
is( $crash_row->get_column('status'),
    'done', 'recovered dispatch acknowledges the outbox row' );
is( scalar @{ $crash_sink->records },
    $POST_HANDLERS, 'recovered dispatch does not rerun handler side effects' );

my $mail_crash_mailer = GPForum::Test::IdentityMailer->new;
my $mail_crash_row    = GPForum::Test::OutboxCrashRow->new(
    data => {
        outbox_id => 'outbox-mail-crash-1',
        payload   => {
            event_id   => 'event-mail-crash-1',
            event_type => 'identity.mail.requested',
            mail       => {
                kind  => 'password_reset',
                to    => 'member@example.test',
                token => 'crash-token',
            },
        },
    },
);
my $mail_crash_clock  = GPForum::Test::OutboxClock->new;
my $mail_crash_schema = GPForum::Test::OutboxSchema->new(
    dead_letter_resultset => GPForum::Test::OutboxCreateResultSet->new,
    outbox_resultset      =>
      GPForum::Test::OutboxResultSet->new( rows => [$mail_crash_row] ),
);
my $mail_crash_transport = GPForum::Service::Outbox::DomainEventTransport->new(
    handlers => [
        GPForum::Worker::Handler::IdentityMail->new(
            mailer => $mail_crash_mailer,
        ),
    ],
    job_runner => _memory_runner(),
);
my $mail_crash_dispatcher = GPForum::Service::Outbox::Dispatcher->new(
    clock     => $mail_crash_clock,
    schema    => $mail_crash_schema,
    transport => $mail_crash_transport,
    worker_id => 'worker-mail-crash',
);
throws_ok(
    sub { $mail_crash_dispatcher->dispatch_pending(1); },
    qr/crash [ ] after [ ] dispatch/msx,
    'identity mail dispatcher can crash after send'
);
is( scalar @{ $mail_crash_mailer->sent },
    $SINGLE_HANDLER, 'crashed identity mail send still delivered once' );
is( $mail_crash_mailer->sent->[0]{token},
    'crash-token', 'crashed identity mail send kept the outbox token' );
is( $mail_crash_row->get_column('status'),
    'running', 'crashed identity mail leaves the outbox row running' );
$mail_crash_clock->now($STALE_LOCK_NOW);
my $mail_recovered = $mail_crash_dispatcher->dispatch_pending(1);
is( $mail_recovered->{dispatched},
    1, 'stale identity mail lock is reclaimed and dispatched' );
is( $mail_crash_row->get_column('status'),
    'done', 'recovered identity mail acknowledges the outbox row' );
is( scalar @{ $mail_crash_mailer->sent },
    $MAIL_RETRY_SENDS,
    'recovered identity mail resends after send-before-ack' );
is( $mail_crash_mailer->sent->[1]{token},
    'crash-token', 'recovered identity mail still has the raw token' );

done_testing();

sub _memory_runner {
    return GPForum::Worker::IdempotentJobRunner->new(
        store => GPForum::Test::IdempotencyStore->new, );
}

sub _transport {
    my ( $sink, $runner, $notifier ) = @_;

    return GPForum::Service::Outbox::DomainEventTransport->new(
        handlers          => _handlers($sink),
        job_runner        => $runner,
        realtime_notifier => $notifier,
    );
}

sub _handlers {
    my ($sink) = @_;

    return [
        GPForum::Worker::Handler::SearchIndexing->new( sink => $sink ),
        GPForum::Worker::Handler::NotificationDispatch->new( sink => $sink ),
        GPForum::Worker::Handler::CacheInvalidation->new( sink => $sink ),
        GPForum::Worker::Handler::AttachmentScanning->new( sink => $sink ),
        GPForum::Worker::Handler::MediaProcessing->new( sink => $sink ),
        GPForum::Worker::Handler::FeedProjection->new( sink => $sink ),
        GPForum::Worker::Handler::IdentityMail->new( sink => $sink ),
        GPForum::Worker::Handler::ReputationUpdate->new( sink => $sink ),
    ];
}

sub _payload_row {
    my ($payload) = @_;

    return GPForum::Test::OutboxPayloadRow->new(
        data => { payload => $payload }, );
}

sub _skipped_count {
    my ($results) = @_;

    my $count = 0;
    for my $row ( @{$results} ) {
        if ( $row->{skipped} ) {
            $count += 1;
        }
    }

    return $count;
}

1;
