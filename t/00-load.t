package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';

our $VERSION = '0.001';

const my $TEST_COUNT => 17;

plan tests => $TEST_COUNT;

use_ok('GPForum');
use_ok('GPForum::Config');
use_ok('GPForum::Runtime');
use_ok('GPForum::Controller::Health');
use_ok('GPForum::Controller::Identity');
use_ok('GPForum::Schema');
use_ok('GPForum::Schema::Result::SchemaVersion');
use_ok('GPForum::Migration::Plan');
use_ok('GPForum::Schema::Result::AuditLog');
use_ok('GPForum::Schema::Result::Credential');
use_ok('GPForum::Schema::Result::EventLog');
use_ok('GPForum::Schema::Result::Session');
use_ok('GPForum::Schema::Result::User');
use_ok('GPForum::Service::Password');
use_ok('GPForum::Service::SessionToken');
use_ok('GPForum::Service::Identity::Registration');
use_ok('GPForum::Service::Identity::Store');

1;
