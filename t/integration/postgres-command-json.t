# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(decode_json);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::Migrate;
use GPForum::Command::PartitionMaintenance;
use GPForum::Command::QueryBudget;
use GPForum::Command::SearchRebuild;
use GPForum::Migration::Plan;
use GPForum::Test::PgDatabase;

our $VERSION = '0.001';

const my $EXIT_OK      => 0;
const my $EXIT_FAILURE => 1;

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run the --json commands';
}

# The --json modes against PostgreSQL: what comes back from the database --
# timestamps, counts, the applied migrations -- must encode, and the status
# must be the database's. t/252-command-json.t holds the shapes.
my $database = GPForum::Test::PgDatabase->fresh;
local $ENV{GPFORUM_DATABASE_DSN} = $database->dsn;
my $dbh = $database->dbh;

my ( $current, $current_status ) =
  _document( GPForum::Command::Migrate->new, '--check', '--json' );
is( $current_status,    $EXIT_OK, 'a migrated database checks clean' );
is( $current->{status}, 'ok',     'and says ok' );
is_deeply( $current->{pending}, [], 'with nothing pending' );

my ( $applied, $applied_status ) =
  _document( GPForum::Command::Migrate->new, '--apply', '--json' );
is( $applied_status, $EXIT_OK, '--apply --json on a current database is 0' );
is_deeply( $applied->{applied}, [], 'and applies nothing' );

my $newest = GPForum::Migration::Plan->new->summary->[-1]{version};
$dbh->do( 'DELETE FROM schema_versions WHERE version = ?', undef, $newest );
my ( $behind, $behind_status ) =
  _document( GPForum::Command::Migrate->new, '--check', '--json' );
is( $behind_status,    $EXIT_FAILURE, 'one unrecorded migration is 1' );
is( $behind->{status}, 'fail',        'and says fail' );
is_deeply( [ map { $_->{version} } @{ $behind->{pending} } ],
    [$newest], 'naming it' );

$dbh->do( q{INSERT INTO outbox_messages (outbox_id, event_id, queue,}
      . q{ job_type, idempotency_key, status, created_at) VALUES}
      . q{ (gen_random_uuid(), gen_random_uuid(), 'events',}
      . q{ 'domain_event.dispatch', 'command-json-lag', 'pending',}
      . q{ now() - interval '5 minutes')} );
my ($lag) =
  _document( GPForum::Command::SearchRebuild->new, '--status', '--json' );
is( $lag->{lag_status}, 'behind', 'search lag reads behind' );
is( $lag->{pending},    1,        'with the message pending' );
like(
    $lag->{oldest_pending_at},
    qr/\A \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ \z/msx,
    'and when the oldest was written, as a string'
);
cmp_ok( $lag->{lag_seconds}, '>=', 1, 'and how long ago in seconds' );

my ( $partitions, $partitions_status ) =
  _document( GPForum::Command::PartitionMaintenance->new, '--plan', '--json' );
is( $partitions_status,    $EXIT_OK, 'partition maintenance plans' );
is( $partitions->{status}, 'ok',     'and says ok' );
ok( defined $partitions->{lookahead_months}, 'with its lookahead' );

my ($budget) =
  _document( GPForum::Command::QueryBudget->new, '--check', '--json' );
ok( defined $budget->{status}, 'the budget check carries a status' );
is( ref $budget->{mismatched}, 'ARRAY', 'and its drift as lists' );

done_testing();

sub _document {
    my ( $command, @arguments ) = @_;

    my $output = q{};
    my $status;
    {
        open my $stdout, '>', \$output or croak 'capture stdout';
        local *STDOUT = $stdout;
        $status = $command->run(@arguments);
        close $stdout or croak 'close stdout';
    }
    my $label = join q{ }, @arguments;
    like( $output, qr/\A [^\n]+ \n \z/msx, "$label prints one line" );
    my $document = eval { decode_json($output) } || {};
    ok( defined $document->{status}, "$label carries a status" )
      or diag $EVAL_ERROR;

    return ( $document, $status );
}

1;
