# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Service::Identity::AccountStore;
use GPForum::Test::UnreachableSchema;
use Test::More;

our $VERSION = '0.001';

const my $USER_ID => '00000000-0000-4000-8000-000000000001';

# The account store's refusals that need no row: a password or an address
# that cannot be right is refused before the database is reached. Every
# case that reads or writes a row runs on PostgreSQL, in
# t/integration/postgres-identity-stores.t.
my $store = GPForum::Service::Identity::AccountStore->new(
    schema => GPForum::Test::UnreachableSchema->new );

is( $store->reset_password( { password => q{}, token => 'raw-1' } )->{error},
    'password_required', 'reset_password rejects an empty password' );
is(
    $store->reset_password( { password => 'too-short', token => 'raw-1' } )
      ->{error},
    'password_too_short',
    'reset_password rejects a short password'
);
is(
    $store->request_email_change( { email => q{}, user_id => $USER_ID } )
      ->{error},
    'email_required',
    'request_email_change rejects an empty email'
);
is(
    $store->request_email_change(
        { email => 'not-an-email', user_id => $USER_ID }
    )->{error},
    'email_invalid',
    'request_email_change rejects an invalid email'
);

done_testing();

1;
