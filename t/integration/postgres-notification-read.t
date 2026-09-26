# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::Migrate;
use GPForum::Service::Notification::Dispatcher;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all =>
      'set GPFORUM_DATABASE_DSN to run the notification read test';
}

# POST /notifications/:notification_id/read takes the id from the URL. One
# that is not a uuid reached the uuid column, failed the statement, and the
# member got a 503 with an error logged for a mistyped link.
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
GPForum::Test::PostgresHarness::quietly(
    sub { return GPForum::Command::Migrate->new->run('--apply') } );

my $dispatcher = GPForum::Service::Notification::Dispatcher->new(
    schema => GPForum::Test::PostgresHarness::connect_schema() );
my $result = eval {
    return $dispatcher->mark_read( 'not-a-uuid',
        '018f1000-0000-7000-8000-00000000a11c' );
};
ok( $result, 'a malformed id does not fail the statement' );
is( $result && $result->{error}, 'not_found', 'it is simply not found' );

GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

1;
