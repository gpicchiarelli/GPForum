package main;

use strict;
use warnings;

use Const::Fast;
use Mojo::File qw(path);
use Test::More;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 51;

plan tests => $EXPECTED_TESTS;

my $prompt_governance = path('prompt/39.txt')->slurp;
my $architecture      = path('prompt/43.txt')->slurp;
my $github_success    = path('prompt/44.txt')->slurp;
my $readme            = path('README.md')->slurp;

like(
    $prompt_governance,
    qr/Prompt [ ] Alignment [ ] Gate/msx,
    'prompt governance defines the alignment gate'
);
like(
    $prompt_governance,
    qr/architecture-changing [ ] commit/msx,
    'prompt governance requires prompt updates for architecture changes'
);
like(
    $prompt_governance,
    qr/automated [ ] tests/msx,
    'prompt governance asks tests to verify alignment'
);
like(
    $architecture,
    qr/prompt [ ] alignment [ ] review/msx,
    'executable architecture includes prompt alignment in DoD'
);
like(
    $readme,
    qr/Prompt [ ] alignment [ ] is [ ] mandatory/msx,
    'README records prompt alignment as a final decision'
);
like(
    $github_success,
    qr/GitHub [ ] Project [ ] Success [ ] Contract/msx,
    'GitHub success prompt defines the project contract'
);
like(
    $github_success,
    qr/CI [ ] for [ ] dependency [ ] installation/msx,
    'GitHub success prompt requires CI'
);
like(
    $readme,
    qr/GitHub [ ] project [ ] success [ ] surface [ ] is [ ] mandatory/msx,
    'README records GitHub success as a final decision'
);

for my $required_term (
    qw(
    command_log
    event_log
    audit_log
    aggregate_stream_versions
    outbox_messages
    projection_offsets
    projection_generations
    partition_registry
    dead_letters
    endpoint_query_budgets
    database_role_contracts
    migration_safety
    schema_versions
    migration_runner
    ThreadComposer
    ThreadStore
    PageWindow
    ThreadReader
    PostReader
    PostComposer
    PostStore
    OutboxDispatcher
    DeadLetterRecorder
    OffsetTracker
    GenerationManager
    DomainEventTransport
    IdempotentJobRunner
    MinionRegistrar
    SearchIndexing
    CacheInvalidation
    SubscriptionStore
    PreferenceStore
    NotificationDispatcher
    DocumentBuilder
    SearchIndexer
    Searcher
    ChannelAuthorizer
    ConnectionRegistry
    RealtimeHub
    post_bodies
    thread_counters
    thread_counter_shards
    search_documents
    )
  )
{
    like( $architecture, qr/\Q$required_term\E/msx,
        "$required_term is represented in executable architecture prompt" );
}

1;
