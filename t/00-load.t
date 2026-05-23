package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

our $VERSION = '0.001';

const my $TEST_COUNT => 69;

plan tests => $TEST_COUNT;

use_ok('GPForum');
use_ok('GPForum::Config');
use_ok('GPForum::Runtime');
use_ok('GPForum::Command::Migrate');
use_ok('GPForum::Controller::Health');
use_ok('GPForum::Controller::Identity');
use_ok('GPForum::Controller::Realtime');
use_ok('GPForum::Schema');
use_ok('GPForum::Schema::Result::SchemaVersion');
use_ok('GPForum::Migration::Plan');
use_ok('GPForum::Migration::Runner');
use_ok('GPForum::Schema::Result::AuditLog');
use_ok('GPForum::Schema::Result::Category');
use_ok('GPForum::Schema::Result::CategoryStat');
use_ok('GPForum::Schema::Result::Credential');
use_ok('GPForum::Schema::Result::DeadLetter');
use_ok('GPForum::Schema::Result::EventLog');
use_ok('GPForum::Schema::Result::Notification');
use_ok('GPForum::Schema::Result::NotificationInbox');
use_ok('GPForum::Schema::Result::NotificationPreference');
use_ok('GPForum::Schema::Result::NotificationRead');
use_ok('GPForum::Schema::Result::OutboxMessage');
use_ok('GPForum::Schema::Result::Post');
use_ok('GPForum::Schema::Result::PostBody');
use_ok('GPForum::Schema::Result::PostRevision');
use_ok('GPForum::Schema::Result::ProjectionGeneration');
use_ok('GPForum::Schema::Result::ProjectionOffset');
use_ok('GPForum::Schema::Result::SearchDocument');
use_ok('GPForum::Schema::Result::Session');
use_ok('GPForum::Schema::Result::Space');
use_ok('GPForum::Schema::Result::Subscription');
use_ok('GPForum::Schema::Result::Thread');
use_ok('GPForum::Schema::Result::ThreadCounter');
use_ok('GPForum::Schema::Result::ThreadCounterShard');
use_ok('GPForum::Schema::Result::User');
use_ok('GPForum::Service::Password');
use_ok('GPForum::Service::SessionToken');
use_ok('GPForum::Service::Identity::Registration');
use_ok('GPForum::Service::Identity::Store');
use_ok('GPForum::Service::Notification::Dispatcher');
use_ok('GPForum::Service::Notification::PreferenceStore');
use_ok('GPForum::Service::Notification::SubscriptionStore');
use_ok('GPForum::Service::Forum::ThreadComposer');
use_ok('GPForum::Service::Forum::ThreadStore');
use_ok('GPForum::Service::Forum::PageWindow');
use_ok('GPForum::Service::Forum::PostReader');
use_ok('GPForum::Service::Forum::ThreadReader');
use_ok('GPForum::Service::Forum::PostComposer');
use_ok('GPForum::Service::Forum::PostStore');
use_ok('GPForum::Service::Outbox::Dispatcher');
use_ok('GPForum::Service::Outbox::DeadLetterRecorder');
use_ok('GPForum::Service::Outbox::DomainEventTransport');
use_ok('GPForum::Service::Outbox::MessageBuilder');
use_ok('GPForum::Service::Projection::OffsetTracker');
use_ok('GPForum::Service::Projection::GenerationManager');
use_ok('GPForum::Service::Realtime::ChannelAuthorizer');
use_ok('GPForum::Service::Realtime::ConnectionRegistry');
use_ok('GPForum::Service::Realtime::Hub');
use_ok('GPForum::Service::Search::DocumentBuilder');
use_ok('GPForum::Service::Search::Indexer');
use_ok('GPForum::Service::Search::Searcher');
use_ok('GPForum::Worker::Handler::CacheInvalidation');
use_ok('GPForum::Worker::Handler::NotificationDispatch');
use_ok('GPForum::Worker::Handler::SearchIndexing');
use_ok('GPForum::Worker::IdempotentJobRunner');
use_ok('GPForum::Worker::MinionRegistrar');
use_ok('GPForum::Test::MigrationDbh');
use_ok('GPForum::Test::MigrationStorage');
use_ok('GPForum::Test::MigrationSchema');

1;
