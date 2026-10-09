# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Admin::Bootstrapper;
use GPForum::Service::Identity::AuthStore;
use GPForum::Service::Moderation::ReportStore;
use GPForum::Service::Notification::Dispatcher;
use GPForum::Test::UnreachableSchema;
use GPForum::X::Argument;
use Test::More;

our $VERSION = '0.001';

# A caller that breaks a service's contract gets a GPForum::X::Argument,
# which says what was missing and nothing else, before any row is read.

sub _error_of ($code) {
    my $error;
    try {
        $code->();
    }
    catch ($caught) {
        $error = $caught;
    };

    return $error;
}

my $bootstrap = _error_of(
    sub {
        GPForum::Service::Admin::Bootstrapper->new(
            schema => GPForum::Test::UnreachableSchema->new )->bootstrap( {} );
    }
);
ok( GPForum::X::Argument->caught($bootstrap),
    'a bootstrap without a user id is an argument error' );
is(
    "$bootstrap",
    'admin bootstrap requires user_id',
    'which names the missing user id and no source line'
);

# A store built without its schema fails where it is built, not on the
# first request that reaches the database.
my $schemaless =
  _error_of( sub { GPForum::Service::Moderation::ReportStore->new } );
ok( GPForum::X::Argument->caught($schemaless),
    'a report store without a schema is refused when built' );
like(
    "$schemaless",
    qr/ReportStore [ ] requires [ ] schema/msx,
    'naming the store and the schema'
);

my $partial = _error_of(
    sub {
        GPForum::Service::Identity::AuthStore->new(
            schema => GPForum::Test::UnreachableSchema->new );
    }
);
like(
    "$partial",
    qr/credential_store .* password .* session_store/msx,
    'an auth store names every collaborator it was built without'
);

# A collaborator only one path reads stays optional: a dispatcher that
# never fans out is built without a subscription store.
my $dispatcher = GPForum::Service::Notification::Dispatcher->new(
    schema => GPForum::Test::UnreachableSchema->new );
ok( !defined $dispatcher->subscription_store,
    'a dispatcher is built without the subscription store only fan-out reads' );

done_testing();

1;
