package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Carp qw(croak);
use Const::Fast;
use GPForum::Command::ScheduledJobs;
use GPForum::Service::Operations::BatchPurge;
use GPForum::Service::Operations::RetentionStore;
use GPForum::Service::Operations::ScheduledJobs;
use GPForum::Test::FixedClock;
use GPForum::Test::PartitionLifecycleProbe;
use GPForum::Test::PurgeSchema;
use GPForum::Test::ScheduledJobStores;
use Test::Exception;
use Test::More;

our $VERSION = '0.001';

const my $BATCH_LIMIT          => 2;
const my $DEFAULT_LIMIT        => 100;
const my $HARD_CAP             => 1_000;
const my $OVERSIZED_LIMIT      => 5_000;
const my $PARTITION_CALLS      => 3;
const my $PROFILE_RETENTION    => 30;
const my $RETENTION_TABLE_JOBS => 5;

my $purge = GPForum::Service::Operations::BatchPurge->new;
is( $purge->limit( {} ), $DEFAULT_LIMIT, 'batch purge defaults to 100' );
is( $purge->limit( { limit => $OVERSIZED_LIMIT } ),
    $HARD_CAP, 'batch purge clamps unbounded-looking limits' );
is_deeply(
    $purge->search_attrs( { limit => $BATCH_LIMIT }, 'expires_at' ),
    {
        order_by => [ { -asc => 'expires_at' } ],
        rows     => $BATCH_LIMIT,
    },
    'search attributes always include a row cap'
);

my $schema = GPForum::Test::PurgeSchema->new;
$schema->add_row(
    'Session',
    {
        expires_at => '2026-05-23T11:00:00Z',
        session_id => 'expired',
    }
);
$schema->add_row(
    'Session',
    {
        expires_at => '2026-05-24T12:00:00Z',
        revoked_at => '2026-05-23T11:00:00Z',
        session_id => 'revoked',
    }
);
$schema->add_row(
    'Session',
    {
        expires_at => '2026-05-24T12:00:00Z',
        session_id => 'live',
    }
);
$schema->add_row(
    'Session',
    {
        expires_at => '2026-05-22T12:00:00Z',
        session_id => 'older-expired',
    }
);
$schema->add_row(
    'IdentityToken',
    {
        expires_at => '2026-05-23T11:00:00Z',
        token_id   => 'expired-token',
    }
);
$schema->add_row(
    'IdentityToken',
    {
        expires_at => '2026-05-24T12:00:00Z',
        token_id   => 'used-token',
        used_at    => '2026-05-23T11:30:00Z',
    }
);
$schema->add_row(
    'IdentityToken',
    {
        expires_at => '2026-05-24T12:00:00Z',
        token_id   => 'live-token',
    }
);
$schema->add_row(
    'RateLimitBucket',
    {
        action            => 'login',
        actor_hash        => 'ab',
        expires_at        => '2026-05-23T11:00:00Z',
        scope             => 'ip',
        window_started_at => '2026-05-23T10:59:00Z',
    }
);
$schema->add_row(
    'RateLimitBucket',
    {
        action            => 'login',
        actor_hash        => 'cd',
        expires_at        => '2026-05-23T12:01:00Z',
        scope             => 'ip',
        window_started_at => '2026-05-23T12:00:00Z',
    }
);
$schema->add_row(
    'OutboxMessage',
    {
        created_at => '2020-01-01T00:00:00Z',
        outbox_id  => 'done-old',
        status     => 'done',
    }
);
$schema->add_row(
    'OutboxMessage',
    {
        created_at => '2020-01-01T00:00:00Z',
        outbox_id  => 'pending-old',
        status     => 'pending',
    }
);
$schema->add_row(
    'OutboxMessage',
    {
        created_at => '2099-01-01T00:00:00Z',
        outbox_id  => 'done-new',
        status     => 'done',
    }
);
$schema->add_row(
    'DeadLetter',
    {
        dead_letter_id => 'old-dead',
        last_failed_at => '2020-01-01T00:00:00Z',
    }
);
$schema->add_row(
    'DeadLetter',
    {
        dead_letter_id => 'new-dead',
        last_failed_at => '2099-01-01T00:00:00Z',
    }
);

my $store = GPForum::Service::Operations::RetentionStore->new(
    clock  => GPForum::Test::FixedClock->new,
    schema => $schema,
);

my $sessions = $store->purge_sessions( { limit => $BATCH_LIMIT } );
is( $sessions->{deleted}, $BATCH_LIMIT, 'session purge honors the batch cap' );
is( $schema->last_resultset->last_attrs->{rows},
    $BATCH_LIMIT, 'session search is limited' );
is_deeply(
    [
        sort map { $_->get_column('session_id') }
          @{ $schema->rows_for('Session') }
    ],
    [ 'live', 'revoked' ],
    'session purge keeps live rows and only the leftover stale batch'
);

my $tokens = $store->purge_identity_tokens( { limit => $DEFAULT_LIMIT } );
is( $tokens->{deleted}, 2, 'token purge deletes expired and used rows' );
is( scalar @{ $schema->rows_for('IdentityToken') },
    1, 'live identity tokens are kept' );

my $buckets = $store->purge_rate_limit_buckets( { limit => $DEFAULT_LIMIT } );
is( $buckets->{deleted}, 1, 'rate-limit purge deletes expired windows only' );

my $outbox = $store->purge_outbox_messages( { limit => $DEFAULT_LIMIT } );
is( $outbox->{deleted}, 1, 'outbox purge deletes completed rows past grace' );
is( scalar @{ $schema->rows_for('OutboxMessage') },
    2, 'pending and recent completed outbox rows are kept' );

my $letters = $store->purge_dead_letters( { limit => $DEFAULT_LIMIT } );
is( $letters->{deleted}, 1, 'dead-letter purge deletes aged rows only' );

my $fakes  = GPForum::Test::ScheduledJobStores->new;
my $probe  = GPForum::Test::PartitionLifecycleProbe->new;
my $runner = GPForum::Service::Operations::ScheduledJobs->new(
    attachment_store    => $fakes,
    clock               => GPForum::Test::FixedClock->new,
    partition_lifecycle => $probe,
    profile             => {
        event_retention_days     => $PROFILE_RETENTION,
        partition_horizon_months => 2,
    },
    retention_store => $fakes,
    schema          => $schema,
);
my $summary = $runner->run( { limit => $BATCH_LIMIT } );
ok( $summary->{ok}, 'scheduled runner reports success' );
is( $summary->{sessions}{limit},
    $BATCH_LIMIT, 'retention jobs receive the batch limit' );
is( scalar @{ $fakes->calls },
    $RETENTION_TABLE_JOBS, 'all retention tables are swept' );
is_deeply(
    [ map { $_->{job} } @{ $fakes->calls } ],
    [
        'sessions',           'identity_tokens',
        'rate_limit_buckets', 'outbox_messages',
        'dead_letters',
    ],
    'retention jobs run in the documented order'
);
is( $fakes->attachment_calls->[0]{limit},
    $BATCH_LIMIT, 'orphan cleanup receives the same batch limit' );
is( $summary->{attachments}{ok}, 1, 'orphan cleanup result is returned' );
is( scalar @{ $probe->calls },
    $PARTITION_CALLS, 'partition policy and evidence are called' );
is_deeply(
    [ map { $_->{method} } @{ $probe->calls } ],
    [ 'plan_window', 'retention_due', 'restore_evidence' ],
    'partition job versions policy and evidence only'
);
is( $probe->calls->[0]{input}{horizon_months},
    2, 'partition planning uses the profile horizon' );
unlike(
    join( q{ }, map { $_->{method} } @{ $probe->calls } ),
    qr/CREATE|PARTITION [ ] OF/msx,
    'partition job does not request DDL'
);

my $filtered = $runner->run(
    {
        jobs  => ['attachments'],
        limit => $BATCH_LIMIT,
    }
);
ok( $filtered->{ok},        'job filter still succeeds' );
ok( !$filtered->{sessions}, 'job filter skips unselected tables' );
is( $filtered->{attachments}{ok}, 1, 'filtered run still cleans orphans' );

my $unknown = $runner->run_job( 'vacuum', { limit => 1 } );
is( $unknown->{error}, 'unknown_job', 'unknown jobs are rejected' );

my $output = _run_command_output( $runner, '--once', '--limit', $BATCH_LIMIT,
    '--job', 'sessions' );
like(
    $output,
    qr/scheduled_jobs [ ] ok=1 [ ] sessions=1/msx,
    'scheduled jobs command prints the operational summary'
);

throws_ok(
    sub {
        GPForum::Command::ScheduledJobs->new( jobs => $runner )
          ->run('--bad-option');
    },
    qr/\A unknown [ ] option [ ] --bad-option/msx,
    'scheduled jobs command rejects unknown options'
);
throws_ok(
    sub {
        GPForum::Command::ScheduledJobs->new( jobs => $runner )
          ->run( '--job', 'vacuum' );
    },
    qr/\A unknown [ ] job [ ] vacuum/msx,
    'scheduled jobs command rejects unknown job names'
);
like( _run_command_output( $runner, '--help' ),
    qr/Usage:/msx, 'scheduled jobs command prints usage' );

done_testing();

sub _run_command_output {
    my ( $jobs, @arguments ) = @_;

    my $captured = q{};
    open my $output_handle, '>', \$captured
      or croak 'failed to open scalar output';
    my $exit = GPForum::Command::ScheduledJobs->new(
        jobs   => $jobs,
        output => $output_handle,
    )->run(@arguments);
    close $output_handle or croak 'failed to close scalar output';
    croak 'scheduled jobs command failed' if $exit;

    return $captured;
}

1;
