package main;

use strict;
use warnings;

use Const::Fast;
use Mojo::File qw(path);
use Test::Fatal;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Domain::EventEnvelope;
use GPForum::Service::Forum::ThreadStore;
use GPForum::Service::Forum::PostStore;
use GPForum::Service::Moderation::ActionStore;
use GPForum::Test::FixedClock;
use GPForum::Test::EngineeringCorrectness::Schema;
use GPForum::Test::Id;
use GPForum::Test::ModerationResultSet;
use GPForum::Test::ModerationSchema;

our $VERSION = '0.001';

const my @CANONICAL_WRITE_STORES => (
    'lib/GPForum/Service/Forum/ThreadStore.pm',
    'lib/GPForum/Service/Forum/PostStore.pm',
    'lib/GPForum/Service/Moderation/ActionStore.pm',
    'lib/GPForum/Service/Moderation/ReportStore.pm',
    'lib/GPForum/Service/Moderation/SuspensionStore.pm',
    'lib/GPForum/Service/Privacy/DeletionWorkflow.pm',
    'lib/GPForum/Service/Privacy/RetentionHoldStore.pm',
);
const my @CONTROLLER_WRITE_METHODS => qw(create update update_or_create delete);
const my @INVARIANT_TEST_FILES => (
    't/11-forum-thread.t',
    't/12-forum-post.t',
    't/25-moderation-review.t',
    't/29-privacy-rights.t',
    't/41-thread-read-state.t',
    't/84-outbox-concurrent-dispatcher.t',
    't/85-realtime-outbox-multiprocess.t',
);
const my @MIGRATION_CONSTRAINTS => (
    [ 'migrations/002_event_audit.sql', qr/event_idempotency_keys_pkey/msx ],
    [
        'migrations/002_event_audit.sql',
        qr/outbox_messages_idempotency_key_key/msx,
    ],
    [ 'migrations/002_event_audit.sql', qr/outbox_messages_status_check/msx ],
    [ 'migrations/003_forum_projection.sql', qr/posts_thread_position_key/msx ],
    [
        'migrations/003_forum_projection.sql',
        qr/thread_counters_reply_count_check/msx,
    ],
    [
        'migrations/004_platform_governance.sql', qr/thread_read_state_pkey/msx,
    ],
    [
        'migrations/004_platform_governance.sql',
        qr/user_read_marker_deltas_pkey/msx,
    ],
    [ 'migrations/008_moderation_review.sql', qr/reports_status_check/msx ],
    [
        'migrations/008_moderation_review.sql',
        qr/moderation_actions_target_type_check/msx,
    ],
    [
        'migrations/022_outbox_concurrent_claim.sql',
        qr/idx_outbox_messages_claim_ready/msx,
    ],
    [
        'migrations/022_outbox_concurrent_claim.sql',
        qr/idx_outbox_messages_pending_ready/msx,
    ],
    [
        'migrations/022_outbox_concurrent_claim.sql',
        qr/idx_outbox_messages_failed_ready/msx,
    ],
    [
        'migrations/022_outbox_concurrent_claim.sql',
        qr/idx_outbox_messages_stale_locks/msx,
    ],
);
const my $AT_SIGN_CODEPOINT => 64;

_assert_canonical_boundaries();
_assert_event_envelope_contract();
_assert_thread_write_failure_rollback();
_assert_reply_and_moderation_concurrency();
_assert_outbox_claim_contract();
_assert_architectural_fitness();
_assert_hot_path_and_cache();
_assert_invariant_test_fixtures();
_assert_migration_constraints();
_assert_engineering_correctness_documentation();

done_testing();

sub _assert_canonical_boundaries {
    subtest
      'canonical writes keep transaction/event/audit/outbox boundaries' => sub {
        _assert_write_store_boundaries();
        _assert_event_recorder_boundary();
      };

    return;
}

sub _assert_write_store_boundaries {
    for my $file (@CANONICAL_WRITE_STORES) {
        my $source = _slurp($file);
        like( $source, qr/->txn_do[(]/msx, "$file uses transaction boundary" );
        like( $source, qr/record_event[(]/msx, "$file records domain event" );
        like( $source, qr/record_audit[(]/msx, "$file records audit event" );
        like( $source, qr/idempotency_key/msx,
            "$file provides event idempotency" );
    }

    return;
}

sub _assert_event_recorder_boundary {
    my $recorder = _slurp('lib/GPForum/Infrastructure/EventRecorder.pm');
    like(
        $recorder,
        qr/resultset[(]'EventLog'[)]->create/msx,
        'event recorder appends EventLog row'
    );
    like(
        $recorder,
        qr/resultset[(]'OutboxMessage'[)][[:space:]]*->create/msx,
        'event recorder appends OutboxMessage row'
    );
    like(
        $recorder,
        qr/resultset[(]'AuditLog'[)]->create/msx,
        'event recorder appends AuditLog row'
    );

    return;
}

sub _assert_event_envelope_contract {
    subtest
      'event envelope exposes contract, version, correlation and idempotency'
      => sub {
        _assert_event_envelope_payload();
      };

    return;
}

sub _assert_event_envelope_payload {
    my $envelope = GPForum::Domain::EventEnvelope->new;
    my $event    = $envelope->record(
        actor_id          => 'user-1',
        aggregate_id      => 'thread-1',
        aggregate_type    => 'thread',
        aggregate_version => 1,
        correlation_id    => 'correlation-1',
        event_id          => 'event-1',
        event_type        => 'thread.created',
        payload           => { title => 'Welcome' },
        schema_version    => 1,
    );
    my $transport = $envelope->transport_payload($event);

    is( $transport->{contract},
        'gpforum.domain_event', 'transport contract is explicit' );
    is( $transport->{contract_version},
        1, 'transport contract version is explicit' );
    is( $transport->{correlation_id},
        'correlation-1', 'correlation id is durable' );
    is( $transport->{idempotency_key},
        'thread.created:thread-1', 'idempotency key is durable' );
    is( $transport->{schema_version}, 1, 'schema version is durable' );

    return;
}

sub _assert_thread_write_failure_rollback {
    subtest 'thread write rolls back when outbox handoff fails' => sub {
        _assert_thread_write_rollback();
    };

    return;
}

sub _assert_thread_write_rollback {
    my $schema = GPForum::Test::EngineeringCorrectness::Schema->new(
        fail_resultset => 'OutboxMessage', );
    my $store = GPForum::Service::Forum::ThreadStore->new(
        id_service => GPForum::Test::Id->new,
        schema     => $schema,
    );

    like(
        exception { $store->create_thread( _thread_command() ) },
        qr/injected [ ] create [ ] failure [ ] for [ ] OutboxMessage/msx,
        'outbox failure is surfaced to the canonical write'
    );
    is( $schema->transactions, 1, 'thread write attempted one transaction' );

    for my $resultset (
        qw(Thread Post PostBody PostRevision ThreadCounter EventLog OutboxMessage AuditLog)
      )
    {
        is( scalar @{ $schema->created_for($resultset) },
            0, "$resultset has no committed row after rollback" );
    }

    return;
}

sub _assert_reply_and_moderation_concurrency {
    subtest 'reply and moderation concurrency invariants are guarded' => sub {
        _assert_duplicate_reply_position_rolls_back();
        _assert_repeated_moderation_action_is_idempotent();
    };

    return;
}

sub _assert_duplicate_reply_position_rolls_back {
    my $schema = GPForum::Test::EngineeringCorrectness::Schema->new(
        unique_post_positions => 1, );
    my $store = GPForum::Service::Forum::PostStore->new(
        id_service => GPForum::Test::Id->new,
        schema     => $schema,
    );

    my $first = $store->create_post( _reply_command('post-1') );
    ok( $first->{ok}, 'first reply commits' );
    like(
        exception { $store->create_post( _reply_command('post-2') ) },
        qr/duplicate [ ] post [ ] position/msx,
        'simultaneous duplicate reply position is rejected'
    );
    is( scalar @{ $schema->created_for('Post') },
        1, 'duplicate reply does not commit a second post' );
    is( scalar @{ $schema->created_for('ThreadCounterShard') },
        1, 'duplicate reply does not commit a second counter delta' );
    is( scalar @{ $schema->created_for('EventLog') },
        1, 'duplicate reply does not commit a second event' );
    is( scalar @{ $schema->created_for('OutboxMessage') },
        1, 'duplicate reply does not commit a second outbox row' );
    is( scalar @{ $schema->created_for('AuditLog') },
        1, 'duplicate reply does not commit a second audit row' );

    return;
}

sub _assert_repeated_moderation_action_is_idempotent {
    my $posts   = GPForum::Test::ModerationResultSet->new;
    my $actions = GPForum::Test::ModerationResultSet->new;
    my $events  = GPForum::Test::ModerationResultSet->new;
    my $outbox  = GPForum::Test::ModerationResultSet->new;
    my $audits  = GPForum::Test::ModerationResultSet->new;
    my $schema  = GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog         => $audits,
            EventLog         => $events,
            ModerationAction => $actions,
            OutboxMessage    => $outbox,
            Post             => $posts,
        },
    );
    $posts->create(
        {
            hidden_at        => undef,
            moderation_state => 'visible',
            post_id          => 'post-1',
        }
    );

    my $store = GPForum::Service::Moderation::ActionStore->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
        schema     => $schema,
    );
    my $first = $store->hide_post( _hide_command() );
    my $again = $store->hide_post( _hide_command() );

    ok( $first->{ok}, 'first moderation action succeeds' );
    ok( $again->{ok}, 'repeated moderation action succeeds' );
    is( $posts->find('post-1')->get_column('moderation_state'),
        'hidden', 'repeated moderation action leaves post hidden' );
    is( $actions->created->[1]{metadata}{idempotent},
        1, 'repeated moderation action is marked idempotent' );

    return;
}

sub _assert_outbox_claim_contract {
    subtest 'outbox dispatcher claim is concurrent and stale-lock safe' => sub {
        _assert_outbox_dispatcher_source();
        _assert_outbox_concurrency_fixture();
    };

    return;
}

sub _assert_outbox_dispatcher_source {
    my $source = _slurp('lib/GPForum/Service/Outbox/Dispatcher.pm');

    like(
        $source,
        qr/sub [ ] claim_ready_batch/msx,
        'dispatcher exposes claim_ready_batch'
    );
    like(
        $source,
        qr/FOR [ ] UPDATE [ ] SKIP [ ] LOCKED/msx,
        'claim uses FOR UPDATE SKIP LOCKED'
    );
    like(
        $source,
        qr/status [ ] IN [ ] [(][?], [ ] [?][)]/msx,
        'claim includes pending and failed rows'
    );
    like(
        $source,
        qr/status [ ] = [ ] [?]/msx,
        'claim includes running stale-lock rows'
    );
    like(
        $source,
        qr/locked_until [ ] <= [ ] [?]::timestamptz/msx,
        'claim recovers expired locks'
    );
    my $stable_claim_order =
      'ORDER BY next_attempt_at ASC, created_at ASC, outbox_id ASC';
    ok( index( $source, $stable_claim_order ) >= 0,
        'claim uses deterministic next-at created-at id ordering' );
    like(
        $source,
        qr/RETURNING [ ] outbox[.][*]/msx,
        'claim returns rows from the atomic update'
    );
    like( $source, qr/ClaimedMessage/msx,
        'PostgreSQL outbox hot path avoids DBIx row reloads' );
    like(
        $source,
        qr/sub [ ] _mark_done_batch_postgresql/msx,
        'PostgreSQL outbox hot path has batch done acknowledgement'
    );
    like(
        $source,
        qr/locked_by [ ] = [ ] [?]/msx,
        'dispatch reads rows claimed by the current worker'
    );

    return;
}

sub _assert_outbox_concurrency_fixture {
    my $test               = _slurp('t/84-outbox-concurrent-dispatcher.t');
    my $worker_counts_line = 'const my ' . chr $AT_SIGN_CODEPOINT;
    $worker_counts_line .= 'WORKER_COUNTS   => ( 2, 4, 8 );';

    ok( index( $test, $worker_counts_line ) >= 0,
        'outbox concurrency test covers 2, 4, and 8 workers' );
    like( $test, qr/duplicate_count/msx,
        'outbox concurrency test verifies duplicate delivery count' );
    like(
        $test,
        qr/stale [ ] running [ ] row [ ] is [ ] claimed/msx,
        'outbox concurrency test verifies stale-lock recovery'
    );
    like(
        $test,
        qr/retryable [ ] row [ ] schedules [ ] backoff/msx,
        'outbox concurrency test verifies retry/backoff'
    );

    return;
}

sub _assert_architectural_fitness {
    subtest 'architectural fitness gates keep writes behind services' => sub {
        _assert_controller_boundaries();
        _assert_template_boundaries();
    };

    return;
}

sub _assert_controller_boundaries {
    for my $file ( _perl_files('lib/GPForum/Controller') ) {
        my $source = $file->slurp;
        unlike(
            $source,
            qr/->resultset[[:space:]]*[(]/msx,
            "$file does not access DBIx::Class resultsets"
        );
        unlike(
            $source,
            qr/DBIx::Class|GPForum::Schema/msx,
            "$file does not depend on persistence classes"
        );
        _assert_no_controller_writes( $file, $source );
    }

    return;
}

sub _assert_no_controller_writes {
    my ( $file, $source ) = @_;

    for my $method (@CONTROLLER_WRITE_METHODS) {
        unlike(
            $source,
            qr/->$method[[:space:]]*[(]/msx,
            "$file does not perform direct $method writes"
        );
    }

    return;
}

sub _assert_template_boundaries {
    for my $file ( _template_files() ) {
        my $source = $file->slurp;
        unlike(
            $source,
            qr/resultset|DBIx::Class|GPForum::Schema/msx,
            "$file renders without persistence access"
        );
        unlike(
            $source,
            qr/->(?:create|update|delete|search)[[:space:]]*[(]/msx,
            "$file renders without business writes or searches"
        );
    }

    return;
}

sub _assert_hot_path_and_cache {
    subtest 'hot path rejects OFFSET and treats cache as disposable' => sub {
        _assert_no_offset_in_hot_path();
        _assert_cache_is_disposable();
    };

    return;
}

sub _assert_no_offset_in_hot_path {
    for my $file ( _perl_files('lib'), _template_files() ) {
        my $source = $file->slurp;
        unlike(
            $source,
            qr/\b OFFSET \b|-> [[:space:]]* search .* offset/msx,
            "$file does not use OFFSET in application hot path"
        );
    }

    return;
}

sub _assert_cache_is_disposable {
    my $cache = _slurp('lib/GPForum/Service/Operations/LocalCache.pm');
    unlike(
        $cache,
        qr/resultset|GPForum::Schema|txn_do/msx,
        'local cache cannot become a persistence authority'
    );
    like( $cache, qr/ttl_seconds/msx, 'local cache has TTL expiry' );
    like( $cache, qr/max_entries/msx, 'local cache has bounded size' );
    like( $cache, qr/invalidate/msx,  'local cache exposes invalidation' );

    return;
}

sub _assert_invariant_test_fixtures {
    subtest 'domain invariant tests are executable release fixtures' => sub {
        _assert_invariant_files_exist();
        _assert_invariant_files_cover_expected_rules();
    };

    return;
}

sub _assert_invariant_files_exist {
    for my $file (@INVARIANT_TEST_FILES) {
        ok( -f $file, "$file exists" );
    }

    return;
}

sub _assert_invariant_files_cover_expected_rules {
    like( _slurp('t/25-moderation-review.t'),
        qr/idempotent/msx, 'moderation tests verify idempotent transitions' );
    like( _slurp('t/29-privacy-rights.t'),
        qr/idempotent/msx, 'privacy tests verify idempotent erasure/retry' );
    like(
        _slurp('t/41-thread-read-state.t'),
        qr/never [ ] regresses/msx,
        'read-state tests verify monotonicity'
    );
    like(
        _slurp('t/85-realtime-outbox-multiprocess.t'),
        qr/polling [ ] fallback/msx,
        'realtime tests verify outbox fallback polling'
    );

    return;
}

sub _assert_migration_constraints {
    subtest 'migration constraints encode correctness invariants' => sub {
        _assert_migration_patterns();
    };

    return;
}

sub _assert_migration_patterns {
    for my $constraint (@MIGRATION_CONSTRAINTS) {
        my ( $file, $pattern ) = @{$constraint};
        like( _slurp($file), $pattern, "$file contains $pattern" );
    }

    return;
}

sub _assert_engineering_correctness_documentation {
    subtest 'engineering correctness documentation is present' => sub {
        _assert_engineering_doc_sections();
    };

    return;
}

sub _assert_engineering_doc_sections {
    my $doc = _slurp('docs/ENGINEERING_CORRECTNESS.md');

    like(
        $doc,
        qr/Engineering [ ] Correctness [ ] Freeze/msx,
        'document names the freeze'
    );
    like( $doc, qr{thread/post}msx, 'document covers thread/post invariants' );
    like( $doc, qr/read-state/msx,  'document covers read-state invariants' );
    like( $doc, qr/moderation/msx,  'document covers moderation invariants' );
    like( $doc, qr/outbox/msx,      'document covers outbox invariants' );
    like( $doc, qr/privacy/msx,     'document covers privacy invariants' );
    like(
        $doc,
        qr/failure [ ] injection/imsx,
        'document covers failure injection'
    );

    return;
}

sub _slurp {
    my ($file) = @_;

    return path($file)->slurp;
}

sub _perl_files {
    my ($root) = @_;

    return grep { "$_" =~ /[.]pm\z/msx } path($root)->list_tree->each;
}

sub _template_files {
    return if !-d 'templates';

    return grep { "$_" =~ /[.]ep\z/msx } path('templates')->list_tree->each;
}

sub _thread_command {
    return {
        thread => {
            author_user_id => 'user-1',
            category_id    => 'category-1',
            thread_id      => 'thread-1',
            title          => 'Welcome',
            visibility     => 'public',
        },
        post => {
            author_user_id => 'user-1',
            post_id        => 'post-1',
            thread_id      => 'thread-1',
        },
        body => {
            body_id     => 'body-1',
            body_source => 'Hello',
        },
        revision => {
            revision_id => 'revision-1',
        },
        counter => {
            thread_id => 'thread-1',
        },
    };
}

sub _reply_command {
    my ($post_id) = @_;

    return {
        post => {
            author_user_id => 'user-1',
            position       => 2,
            post_id        => $post_id,
            thread_id      => 'thread-1',
        },
        body => {
            body_id     => 'body-' . $post_id,
            body_source => 'Reply',
        },
        revision => {
            revision_id => 'revision-' . $post_id,
        },
        counter_shard => {
            shard_id  => 0,
            thread_id => 'thread-1',
        },
    };
}

sub _hide_command {
    return {
        actor_user_id => 'moderator-1',
        post_id       => 'post-1',
        reason        => 'spam',
    };
}

1;
