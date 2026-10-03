# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Mojo::JSON qw(decode_json);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::QueryBudget;
use GPForum::Service::Operations::QueryBudget;
use GPForum::Test::PgDatabase;

our $VERSION = '0.001';

const my $EXIT_OK      => 0;
const my $EXIT_FAILURE => 1;

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run the query budget sync';
}

# script/query-budget --sync against PostgreSQL. It writes the catalog into
# endpoint_query_budgets -- and deletes the rows of endpoints the catalog no
# longer has. It used to leave those, so --check reported them extra after
# every sync, and readiness failed on query_budget_drift, until someone
# deleted the row by hand.
my $database = GPForum::Test::PgDatabase->fresh;
local $ENV{GPFORUM_DATABASE_DSN} = $database->dsn;
my $dbh     = $database->dbh;
my $catalog = GPForum::Service::Operations::QueryBudget->new->catalog;

my ( $first, $first_status ) = _run( '--sync', '--json' );
is( $first_status,    $EXIT_OK,                'the first sync succeeds' );
is( $first->{synced}, scalar keys %{$catalog}, 'and covers the catalog' );
is_deeply( $first->{removed}, [], 'removing nothing from an empty table' );
is( _stored(), scalar keys %{$catalog}, 'one row per catalog endpoint' );

$dbh->do(
    q{INSERT INTO endpoint_query_budgets (endpoint_name, max_queries,}
      . q{ max_transactions, notes) VALUES (?, 3, 1, ?), (?, 4, 1, ?)},
    undef,
    'dropped_endpoint',
    'an endpoint an older release had',
    'retired_endpoint',
    'another one',
);
$dbh->do( q{UPDATE endpoint_query_budgets SET max_queries = 1}
      . q{ WHERE endpoint_name = 'thread_view'} );

my ( $drift, $drift_status ) = _run( '--check', '--json' );
is( $drift_status, $EXIT_FAILURE, 'the check fails on the extra rows' );
is_deeply(
    $drift->{extra},
    [ 'dropped_endpoint', 'retired_endpoint' ],
    'naming each endpoint the catalog dropped'
);
is_deeply( $drift->{mismatched}, ['thread_view'], 'and the drifted one' );

my ( $text, $text_status ) = _run_text('--sync');
is( $text_status, $EXIT_OK, 'the sync succeeds' );
my ($removed_line) = grep { /\A removed [ ]/msx } split /\n/msx, $text;
is(
    $removed_line,
    'removed 2 dropped endpoint query budgets: '
      . 'dropped_endpoint,retired_endpoint',
    'and says which rows it deleted'
);
is( _stored(), scalar keys %{$catalog}, 'leaving one row per endpoint' );
my ($thread_view) =
  $dbh->selectrow_array( q{SELECT max_queries FROM endpoint_query_budgets}
      . q{ WHERE endpoint_name = 'thread_view'} );
is(
    $thread_view,
    $catalog->{thread_view}{max_queries},
    'with the drifted budget restored'
);

my ( $clean, $clean_status ) = _run( '--check', '--json' );
is( $clean_status,    $EXIT_OK, 'the check passes after that sync' );
is( $clean->{status}, 'ok',     'and says ok' );

$dbh->do(
    q{INSERT INTO endpoint_query_budgets (endpoint_name, max_queries,}
      . q{ max_transactions, notes) VALUES (?, 2, 1, ?)},
    undef, 'renamed_endpoint', 'the name a later release changed',
);
my ( $json, $json_status ) = _run( '--sync', '--json' );
is( $json_status, $EXIT_OK, 'the JSON sync succeeds' );
is_deeply( $json->{removed}, ['renamed_endpoint'],
    'and names in removed the row it deleted' );
is( _stored(), scalar keys %{$catalog}, 'leaving the catalog again' );

my ( $again, $again_status ) = _run( '--sync', '--json' );
is( $again_status, $EXIT_OK, 'a second sync succeeds' );
is_deeply( $again->{removed}, [], 'and has nothing left to remove' );

done_testing();

sub _stored {
    my ($count) =
      $dbh->selectrow_array(q{SELECT count(*) FROM endpoint_query_budgets});

    return $count;
}

sub _run {
    my (@arguments) = @_;

    my ( $output, $status ) = _run_text(@arguments);

    return ( decode_json($output), $status );
}

sub _run_text {
    my (@arguments) = @_;

    my $output = q{};
    open my $capture, '>', \$output or croak 'capture stdout';
    my $status;
    {
        local *STDOUT = $capture;
        $status = GPForum::Command::QueryBudget->new->run(@arguments);
    }
    close $capture or croak 'close stdout';

    return ( $output, $status );
}

1;
