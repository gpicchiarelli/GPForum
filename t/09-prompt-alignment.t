package main;

use strict;
use warnings;

use Const::Fast;
use Mojo::File qw(path);
use Test::More;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 153;

plan tests => $EXPECTED_TESTS;

my $prompt_governance = path('prompt/39.txt')->slurp;
my $architecture      = path('prompt/43.txt')->slurp;
my $github_success    = path('prompt/44.txt')->slurp;
my $engineering       = path('prompt/45.txt')->slurp;
my $accessibility     = path('prompt/46.txt')->slurp;
my $community         = path('prompt/47.txt')->slurp;
my $discipline        = path('prompt/48.txt')->slurp;
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
like(
    $engineering,
    qr/Verifiable [ ] Engineering [ ] Invariants [ ] Constitution/msx,
    'engineering invariants prompt defines the new constitution'
);
like(
    $engineering,
    qr/architecture-by-verifiable-invariants/msx,
    'engineering invariants prompt defines verifiable architecture'
);
like( $engineering, qr/InvariantViolation/msx,
    'engineering invariants prompt defines invariant failure taxonomy' );
like(
    $engineering,
    qr/Controllers [ ] MUST [ ] NOT .* DBIx::Class [ ] resultsets/msx,
    'engineering invariants prompt forbids direct controller persistence'
);
like(
    $engineering,
    qr/Every [ ] migration [ ] MUST [ ] document/msx,
    'engineering invariants prompt defines migration discipline'
);
like(
    $engineering,
    qr/Releases [ ] are [ ] operational [ ] events/msx,
    'engineering invariants prompt defines release discipline'
);
like(
    $readme,
    qr/48 [ ] architectural [ ] prompt [ ] constitutions/msx,
'README counts the verifiable, accessibility, community, and discipline constitutions'
);
like(
    $readme,
    qr/Architecture-by-verifiable-invariants [ ] is [ ] mandatory/msx,
    'README records verifiable invariants as a final decision'
);
like(
    $accessibility,
    qr/Accessibility [ ] Engineering [ ] Constitution/msx,
    'accessibility prompt defines the new constitution'
);
like(
    $accessibility,
    qr/WCAG [ ] 2[.]2 [ ] AA [ ] compliance/msx,
    'accessibility prompt requires WCAG 2.2 AA'
);
like(
    $accessibility,
    qr/Semantic [ ] HTML [ ] is [ ] preferred [ ] over [ ] ARIA/msx,
    'accessibility prompt defines semantic HTML doctrine'
);
like(
    $accessibility,
    qr/Keyboard [ ] users [ ] are [ ] first-class [ ] participants/msx,
    'accessibility prompt defines keyboard users as first-class'
);
like(
    $accessibility,
    qr/Themes [ ] cannot [ ] degrade [ ] below [ ] WCAG [ ] 2[.]2 [ ] AA/msx,
    'accessibility prompt governs theme accessibility'
);
like(
    $accessibility,
    qr/Plugins [ ] MUST .* preserve [ ] semantic [ ] rendering/msx,
    'accessibility prompt governs plugin accessibility'
);
like(
    $readme,
    qr/48 [ ] architectural [ ] prompt [ ] constitutions/msx,
    'README counts the accessibility constitution'
);
like(
    $readme,
    qr/Accessibility [ ] engineering [ ] is [ ] mandatory/msx,
    'README records accessibility as a final decision'
);
like(
    $engineering,
    qr/Accessibility [ ] invariants [ ] from [ ] prompt\/46[.]txt/msx,
    'engineering invariants prompt includes accessibility invariants'
);
like(
    $community,
    qr/Human-Centered [ ] Community [ ] Lifecycle [ ] Constitution/msx,
    'community lifecycle prompt defines the new constitution'
);
like(
    $community,
    qr/Forums [ ] are [ ] social [ ] memory [ ] systems/msx,
    'community lifecycle prompt defines forums as social memory'
);
ok(
    index( $community, 'anonymous visitor' ) >= 0
      && index( $community, 'newcomer' ) >= 0
      && index( $community, 'trusted contributor' ) >= 0
      && index( $community, 'long-term steward' ) >= 0,
    'community lifecycle prompt defines lifecycle stages'
);
like(
    $community,
    qr/Retention [ ] MUST [ ] emerge [ ] from [ ] value/msx,
    'community lifecycle prompt rejects addiction loops'
);
like(
    $community,
    qr/Infinite-scroll [ ] addiction [ ] traps [ ] are [ ] prohibited/msx,
    'community lifecycle prompt prohibits infinite-scroll traps'
);
like(
    $discipline,
    qr/Core [ ] Boundary/msx,
    'core discipline prompt defines the new constitution'
);
like(
    $discipline,
    qr/The [ ] GPForum [ ] core [ ] MUST [ ] remain [ ] small/msx,
    'core discipline prompt requires small core'
);
like(
    $discipline,
    qr/Controllers [ ] MUST [ ] NOT [ ] contain [ ] business [ ] logic/msx,
    'core discipline prompt forbids controller business logic'
);
like(
    $discipline,
    qr/Plugins [ ] MUST [ ] declare [ ] capabilities/msx,
    'core discipline prompt requires plugin capabilities'
);
like(
    $discipline,
qr/Cache [ ] MUST [ ] NEVER [ ] be [ ] the [ ] sole [ ] source [ ] of [ ] truth/msx,
    'core discipline prompt forbids cache authority'
);
like(
    $readme,
    qr/Human-centered [ ] community [ ] lifecycle/msx,
    'README records human-centered community lifecycle as final decision'
);
like(
    $readme,
    qr/Core [ ] boundary [ ] discipline [ ] is [ ] mandatory/msx,
    'README records core boundary discipline as final decision'
);
like(
    $engineering,
    qr/Community [ ] lifecycle [ ] invariants [ ] from [ ] prompt\/47[.]txt/msx,
    'engineering invariants prompt includes community lifecycle invariants'
);
like(
    $engineering,
    qr/Core [ ] boundary [ ] rules [ ] from [ ] prompt\/48[.]txt/msx,
    'engineering invariants prompt includes core boundary invariants'
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
    AttachmentValidator
    AttachmentIntentBuilder
    AttachmentStore
    AttachmentScanning
    MediaProcessing
    attachment_links
    RateLimiter
    MetricsSnapshot
    RunbookValidator
    RuntimeSizing
    MentionExtractor
    BookmarkStore
    ReputationLedger
    FeedProjector
    bookmarks
    mentions
    reputation_events
    trust_score_snapshots
    user_feed_items
    ReportStore
    ActionStore
    AuditReview
    reports
    moderation_actions
    suspensions
    RoleCatalog
    RoleBindingStore
    PermissionReview
    roles
    permissions
    role_permissions
    role_bindings
    resource_acl
    admin_role_audit_projection
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
    ImportManifestValidator
    ImportJobStore
    LegacyIdMapper
    ExportBundleBuilder
    import_jobs
    import_failures
    legacy_id_map
    export_requests
    PluginManifestValidator
    PluginRegistry
    HookDispatcher
    PluginFailureRecorder
    plugins
    plugin_hooks
    plugin_failures
    DeletionWorkflow
    RetentionHoldStore
    DataRightsReview
    deletion_requests
    deletion_actions
    erasure_jobs
    retention_holds
    account_deletion
    data_rights
    legal_hold
    CanonicalUrl
    MetadataBuilder
    RobotsPolicy
    SitemapBuilder
    FeedBuilder
    VisibilityPolicy
    canonical_url
    robots_txt
    sitemap
    public_feed
    noindex
    public_discovery
    )
  )
{
    like( $architecture, qr/\Q$required_term\E/msx,
        "$required_term is represented in executable architecture prompt" );
}

1;
