# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::AdminBootstrap;
use GPForum::Service::Operations::LocalCache;
use GPForum::Service::Operations::SharedCache;
use GPForum::Service::Operations::TieredCache;
use GPForum::Service::Password;
use GPForum::Test::OperationsClock;
use GPForum::Test::PgDatabase;
use GPForum::Test::PostgresHarness;
use GPForum::Test::SharedCacheClient;

our $VERSION = '0.001';

const my $HTTP_OK     => 200;
const my $HTTP_FOUND  => 302;
const my $PASSWORD    => 'correct horse battery staple';
const my $ADMIN       => 'purge_admin';
const my $JSON        => { Accept => 'application/json' };
const my $PAUSE       => 3_600;
const my @PURGED_TAGS => qw(forum:public-html categories forum-index);
const my $PURGES_SQL =>
  q{SELECT metadata->>'status' FROM audit_log WHERE actor_id = ?}
  . q{ AND action = 'admin.cache_purged' ORDER BY 1};

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the admin purge test';
}

# The console's "Purge page cache", against the application and PostgreSQL.
# A purge GlifiStore did not take -- paused after a failure, or failing now --
# leaves its copies current until their TTL, and the jobs page said "purged"
# all the same: an operator who purged to take a page down believed it down.
# The page now warns and names the tags left, the JSON says so, and the
# answer stored under the command id (jsonb in command_log) says so again
# when the form is resubmitted.
local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;

my $database = GPForum::Test::PgDatabase->fresh;
local $ENV{GPFORUM_DATABASE_DSN} = $database->dsn;
my $dbh      = $database->dbh;
my $admin_id = _administrator();

my $shared = GPForum::Service::Operations::SharedCache->new(
    client    => GPForum::Test::SharedCacheClient->new,
    clock     => GPForum::Test::OperationsClock->new,
    namespace => 'purge',
);
my $cache = GPForum::Service::Operations::TieredCache->new(
    l1 => GPForum::Service::Operations::LocalCache->new,
    l2 => $shared,
);
my $client = Test::Mojo->new('GPForum');
$client->app->helper( gp_local_cache => sub { return $cache; } );
_sign_in();

# GlifiStore answers: the purge is purged.
$client->post_ok( '/admin/cache/purge' => form => _purge_form() );
$client->status_is($HTTP_FOUND)->header_is( Location => '/admin/jobs' );
$client->get_ok('/admin/jobs')
  ->text_is( 'p.flash--success' => 'Public page cache purged.' )
  ->element_exists_not( 'p.flash--warning',
    'a purge GlifiStore took is confirmed' );
$client->post_ok( '/admin/cache/purge' => $JSON => form => _purge_form() );
$client->status_is($HTTP_OK)->json_is( '/status' => 'cache_purged' );
$client->json_is( '/result/status' => 'purged' )
  ->json_is( '/result/unreached_tags' => [] );

# GlifiStore paused: every process's own copy is gone, its copies are not.
$shared->retry_after_epoch( $shared->clock->now_epoch + $PAUSE );
$client->post_ok( '/admin/cache/purge' => $JSON => form => _purge_form() );
$client->status_is($HTTP_OK)->json_is( '/status' => 'cache_purged_locally' );
$client->json_is( '/result/status' => 'purged_locally' )
  ->json_is( '/result/unreached_tags' => [@PURGED_TAGS] );

my $partial = _purge_form();
$client->post_ok( '/admin/cache/purge' => form => $partial );
$client->status_is($HTTP_FOUND);
_warned('a purge GlifiStore did not take is a warning naming its tags');

# The same form again replays the answer stored under its command id, read
# back from PostgreSQL: still the warning, with the same tags, and no second
# purge or audit row.
$shared->retry_after_epoch(undef);
$client->post_ok( '/admin/cache/purge' => form => $partial );
$client->status_is($HTTP_FOUND);
_warned('and so is the same form resubmitted once GlifiStore is back');
is_deeply(
    $dbh->selectcol_arrayref( $PURGES_SQL, undef, $admin_id ),
    [qw(purged purged purged_locally purged_locally)],
    'each purge is audited once, with how far it went'
);

done_testing();

sub _warned {
    my ($name) = @_;

    $client->get_ok('/admin/jobs')->element_exists_not('p.flash--success');
    $client->text_is(
        'p.flash--warning[role="status"]' =>
          'Public page cache purged in the web processes only: the shared'
          . ' cache was unreachable, so its entries expire within their TTL.'
          . ' Not reached: '
          . join( q{, }, @PURGED_TAGS ) . q{.},
        $name
    );

    return;
}

# The purge form as the jobs page renders it: its CSRF token and the command
# id it carries.
sub _purge_form {
    $client->get_ok('/admin/jobs')->status_is($HTTP_OK);
    my $page    = $client->tx->res->dom;
    my $purge   = 'form[action="/admin/cache/purge"]';
    my $command = $page->at("$purge input[name=command_id]");
    my $csrf    = $page->at("$purge input[name=csrf_token]");

    return {
        command_id => $command ? $command->attr('value') : q{},
        csrf_token => $csrf    ? $csrf->attr('value')    : q{},
    };
}

sub _sign_in {
    $client->get_ok('/login');
    my $login = $client->tx->res->dom;
    $client->post_ok(
        '/login' => form => {
            command_id => $login->at('input[name=command_id]')->attr('value'),
            csrf_token => $login->at('input[name=csrf_token]')->attr('value'),
            identifier => $ADMIN,
            password   => $PASSWORD,
        }
    );
    $client->get_ok('/admin/jobs')
      ->status_is( $HTTP_OK, 'the administrator signs in' );

    return;
}

# A user with a password, given the bootstrap administration role.
sub _administrator {
    my $hash = GPForum::Service::Password->new->hash_password($PASSWORD);
    my ($id) = $dbh->selectrow_array(
        q{INSERT INTO users (id, username, display_name, email_normalized,}
          . q{ password_hash, status) VALUES (gen_random_uuid(), ?,}
          . q{ 'Purge admin', 'purge-admin@example.test', ?, 'active')}
          . q{ RETURNING id},
        undef, $ADMIN, $hash
    );
    $dbh->do(
        q{INSERT INTO credentials (id, user_id, type, secret_hash)}
          . q{ VALUES (gen_random_uuid(), ?, 'password', ?)},
        undef, $id, $hash
    );
    is(
        GPForum::Test::PostgresHarness::quietly(
            sub {
                return GPForum::Command::AdminBootstrap->new->run( '--user-id',
                    $id );
            }
        ),
        0,
        'the administrator receives the bootstrap role'
    );

    return $id;
}

1;
