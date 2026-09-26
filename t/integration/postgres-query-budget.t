# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Password;
use GPForum::Test::PgDatabase;

our $VERSION = '0.001';

const my $HTTP_OK   => 200;
const my $PASSWORD  => 'correct horse battery';
const my $FEW_ROWS  => 1;
const my $MANY_ROWS => 50;

# Statements each page may execute, as measured on 2026-09-26. Raising one
# is a decision to write down in the commit, not a number to bump.
const my %BUDGET => (
    anonymous => {
        categories => 1,
        category   => 2,
        home       => 2,
        profile    => 6,
        search     => 3,
        thread     => 3,
    },
    'signed in' => {
        bookmarks     => 3,
        categories    => 3,
        category      => 4,
        feed          => 3,
        home          => 4,
        notifications => 4,
        profile       => 7,
        search        => 5,
        thread        => 8,
    },
);

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run the query budget';
}

# How many statements each page sends to PostgreSQL, against the seeded
# forum (quality program: "a query budget per request"). A page that grows a
# query per row -- an N+1 -- sends more statements for fifty rows than for
# one; every page here must send the same number for both. And each page
# must stay within the budget measured when this test was written, so a new
# query on a hot page is a decision, not an accident.
local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;
my $database = GPForum::Test::PgDatabase->fresh( seed => 1 );
local $ENV{GPFORUM_DATABASE_DSN} = $database->dsn;
my $dbh = $database->dbh;

my ($category) = $dbh->selectrow_array(
        q{SELECT c.category_id FROM categories c JOIN threads t}
      . q{ ON t.category_id = c.category_id WHERE c.visibility = 'public'}
      . q{ AND t.deleted_at IS NULL GROUP BY c.category_id}
      . q{ ORDER BY count(*) DESC LIMIT 1} );
my ($thread) =
  $dbh->selectrow_array( q{SELECT t.thread_id FROM threads t JOIN posts p}
      . q{ ON p.thread_id = t.thread_id WHERE t.deleted_at IS NULL}
      . q{ AND t.visibility = 'public' AND t.moderation_state = 'visible'}
      . q{ GROUP BY t.thread_id ORDER BY count(*) DESC LIMIT 1} );
my ($author) =
  $dbh->selectrow_array( q{SELECT u.username FROM users u JOIN threads t}
      . q{ ON t.author_user_id = u.id WHERE u.status = 'active' LIMIT 1} );
my $member = _member();

my %pages = (
    category   => "/c/$category",
    categories => '/categories',
    home       => q{/},
    profile    => "/u/$author",
    search     => '/search?q=the',
    thread     => "/t/$thread",
);
my %signed_in_pages = (
    %pages,
    bookmarks     => '/bookmarks',
    feed          => '/feed',
    notifications => '/notifications',
);

my %executed;
my $anonymous = _instrumented('anonymous');
my $signed_in = _instrumented('signed in');
_sign_in($signed_in);

for my $name ( sort keys %pages ) {
    _check( $anonymous, 'anonymous', $name, $pages{$name} );
}
for my $name ( sort keys %signed_in_pages ) {
    _check( $signed_in, 'signed in', $name, $signed_in_pages{$name} );
}

# The comparison proves something only if fifty rows are shown.
cmp_ok( _rows( "/t/$thread", 'article[id^="post-"]' ),
    q{>}, $FEW_ROWS, 'the thread page shows more than one post' );
cmp_ok( _rows( "/c/$category", 'a[href^="/t/"]' ),
    q{>}, $FEW_ROWS, 'the category page lists more than one thread' );

done_testing();

sub _check {
    my ( $client, $who, $name, $path ) = @_;

    my $separator = $path =~ /[?]/msx ? q{&} : q{?};
    _statements( $client, $who, "$path${separator}limit=$MANY_ROWS&warm=1" );
    my $few = _statements( $client, $who, "$path${separator}limit=$FEW_ROWS" );
    my $many =
      _statements( $client, $who, "$path${separator}limit=$MANY_ROWS" );
    diag(
        "$who $name: $few statements for $FEW_ROWS rows, $many for $MANY_ROWS");
    is( $many, $few, "$who $name: fifty rows cost no more queries than one" );
    cmp_ok(
        $many, q{<=},
        $BUDGET{$who}{$name},
        "$who $name: within its budget of $BUDGET{$who}{$name}"
    );

    return;
}

# An application whose handle counts every statement it executes, before
# it has prepared any: a statement cached later is still counted each time
# it runs (counting prepares missed those). DBI runs selectrow_array,
# selectrow_arrayref and selectall_arrayref without calling execute, so
# those are counted where they are called.
sub _instrumented {
    my ($who) = @_;

    my $client  = Test::Mojo->new('GPForum');
    my $schema  = $client->app->build_controller->gp_schema;
    my $storage = $schema->storage;
    my $count   = sub { $executed{$who}++; return; };
    $storage->dbh->{Callbacks} = {
        ChildCallbacks     => { execute => $count },
        do                 => $count,
        selectall_arrayref => $count,
        selectrow_array    => $count,
        selectrow_arrayref => $count,
    };

    return $client;
}

# Statements one page executes.
sub _statements {
    my ( $client, $who, $path ) = @_;

    # Each page is built, not answered from the page cache or the category
    # list's: they ignore parameters other than the page size.
    my $cache = $client->app->build_controller->gp_local_cache;
    for my $tag (qw(forum:public-html categories forum-index)) {
        $cache->invalidate_tag($tag);
    }
    $executed{$who} = 0;
    $client->get_ok( $path => { 'Accept-Language' => 'en' } )
      ->status_is($HTTP_OK);

    return $executed{$who};
}

sub _rows {
    my ( $path, $selector ) = @_;

    $anonymous->get_ok("$path?limit=$MANY_ROWS&rows=1");

    return $anonymous->tx->res->dom->find($selector)->size;
}

sub _member {
    my $hash = GPForum::Service::Password->new->hash_password($PASSWORD);
    my ($id) = $dbh->selectrow_array(
        q{INSERT INTO users (id, username, display_name, email_normalized,}
          . q{ password_hash, status) VALUES (gen_random_uuid(), 'budget',}
          . q{ 'Budget', 'budget@example.test', ?, 'active') RETURNING id},
        undef, $hash
    );
    $dbh->do(
        q{INSERT INTO credentials (id, user_id, type, secret_hash)}
          . q{ VALUES (gen_random_uuid(), ?, 'password', ?)},
        undef, $id, $hash
    );

    return $id;
}

sub _sign_in {
    my ($client) = @_;

    $client->get_ok('/login');
    my $form    = $client->tx->res->dom;
    my $csrf    = $form->at('input[name=csrf_token]')->attr('value');
    my $command = $form->at('input[name=command_id]')->attr('value');
    $client->post_ok(
        '/login' => form => {
            command_id => $command,
            csrf_token => $csrf,
            identifier => 'budget',
            password   => $PASSWORD,
        }
    );
    $client->get_ok('/settings')->status_is( $HTTP_OK, 'the member signs in' );

    return;
}

1;
