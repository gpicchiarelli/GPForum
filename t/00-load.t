package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

our $VERSION = '0.001';

const my $TEST_COUNT => 31;

plan tests => $TEST_COUNT;

use_ok('GPForum');
use_ok('GPForum::Config');
use_ok('GPForum::Runtime');
use_ok('GPForum::Command::Migrate');
use_ok('GPForum::Controller::Health');
use_ok('GPForum::Controller::Identity');
use_ok('GPForum::Schema');
use_ok('GPForum::Schema::Result::SchemaVersion');
use_ok('GPForum::Migration::Plan');
use_ok('GPForum::Migration::Runner');
use_ok('GPForum::Schema::Result::AuditLog');
use_ok('GPForum::Schema::Result::Category');
use_ok('GPForum::Schema::Result::CategoryStat');
use_ok('GPForum::Schema::Result::Credential');
use_ok('GPForum::Schema::Result::EventLog');
use_ok('GPForum::Schema::Result::Post');
use_ok('GPForum::Schema::Result::PostBody');
use_ok('GPForum::Schema::Result::PostRevision');
use_ok('GPForum::Schema::Result::SearchDocument');
use_ok('GPForum::Schema::Result::Session');
use_ok('GPForum::Schema::Result::Space');
use_ok('GPForum::Schema::Result::Thread');
use_ok('GPForum::Schema::Result::ThreadCounter');
use_ok('GPForum::Schema::Result::User');
use_ok('GPForum::Service::Password');
use_ok('GPForum::Service::SessionToken');
use_ok('GPForum::Service::Identity::Registration');
use_ok('GPForum::Service::Identity::Store');
use_ok('GPForum::Test::MigrationDbh');
use_ok('GPForum::Test::MigrationStorage');
use_ok('GPForum::Test::MigrationSchema');

1;
