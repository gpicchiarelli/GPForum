package main;

use strict;
use warnings;

use Const::Fast;
use Mojo::File qw(path);
use Test::More;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 297;

plan tests => $EXPECTED_TESTS;

my $prompt_governance = path('prompt/39.txt')->slurp;
my $architecture      = path('prompt/43.txt')->slurp;
my $github_success    = path('prompt/44.txt')->slurp;
my $engineering       = path('prompt/45.txt')->slurp;
my $accessibility     = path('prompt/46.txt')->slurp;
my $community         = path('prompt/47.txt')->slurp;
my $discipline        = path('prompt/48.txt')->slurp;
my $os_performance    = path('prompt/49.txt')->slurp;
my $execution         = path('prompt/50.txt')->slurp;
my $scalability       = path('prompt/51.txt')->slurp;
my $domain_integrity  = path('prompt/52.txt')->slurp;
my $retrieval         = path('prompt/53.txt')->slurp;
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
    qr/53 [ ] architectural [ ] prompt [ ] constitutions/msx,
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
    qr/53 [ ] architectural [ ] prompt [ ] constitutions/msx,
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
like(
    $os_performance,
    qr/OS-Level [ ] Performance [ ] Constitution/msx,
    'OS performance prompt defines the new constitution'
);
like(
    $os_performance,
    qr/macOS, [ ] FreeBSD, [ ] and [ ] Linux/msx,
    'OS performance prompt defines supported systems'
);
like( $os_performance, qr/GPForum::OS/msx,
    'OS performance prompt requires centralized OS abstraction' );
like(
    $os_performance,
    qr/fork [ ] per [ ] request/msx,
    'OS performance prompt forbids fork per request'
);
like( $os_performance, qr/SO_REUSEPORT/msx,
    'OS performance prompt defines socket capability policy' );
like(
    $os_performance,
    qr/Templates [ ] MUST [ ] render/msx,
    'OS performance prompt forbids template business logic'
);
like(
    $os_performance,
    qr/GPForum [ ] MUST [ ] NOT [ ] require [ ] Redis/msx,
    'OS performance prompt preserves Redis optionality'
);
like(
    $readme,
    qr/OS-level [ ] performance [ ] discipline [ ] is [ ] mandatory/msx,
    'README records OS performance as a final decision'
);
like(
    path('prompt/15.txt')->slurp,
    qr/Prompt [ ] 49 [ ] alignment/msx,
    'performance prompt aligns with OS performance constitution'
);
like(
    path('prompt/38.txt')->slurp,
    qr/Prompt [ ] 49 [ ] alignment/msx,
    'deployment prompt aligns with OS performance constitution'
);
like(
    path('prompt/40.txt')->slurp,
    qr/Prompt [ ] 49 [ ] alignment/msx,
    'multi-process prompt aligns with OS performance constitution'
);
like(
    path('prompt/41.txt')->slurp,
    qr/Prompt [ ] 49 [ ] alignment/msx,
    'profiling prompt aligns with OS performance constitution'
);
ok(
    index( $engineering,
        'OS-level performance rules are engineering invariants' ) >= 0,
    'engineering invariants prompt aligns with OS performance constitution'
);

like(
    $execution,
    qr/Execution [ ] Constitution [ ] For [ ] Operational [ ] Integrity/msx,
    'execution prompt defines the new constitution'
);
like(
    $execution,
    qr/core [ ] operational [ ] architecture [ ] stabilization/msx,
    'execution prompt names the current stabilization phase'
);
ok(
    index( $execution,
        'The existing GPForum repository is authoritative reality' ) >= 0,
    'execution prompt treats repository reality as authoritative'
);
like(
    $execution,
    qr/Controllers [ ] MUST [ ] remain [ ] thin/msx,
    'execution prompt preserves thin controllers'
);
like(
    $execution,
    qr/bypass [ ] event [ ] generation/msx,
    'execution prompt forbids bypassing events'
);
like(
    $execution,
    qr/bypass [ ] audit [ ] generation/msx,
    'execution prompt forbids bypassing audit'
);
like(
    $execution,
    qr/Projection [ ] tables [ ] remain [ ] derived/msx,
    'execution prompt preserves derived projections'
);
like(
    $execution,
    qr/Private, [ ] moderated, [ ] hidden, [ ] suspended, [ ] deleted/msx,
    'execution prompt forbids restricted content leakage'
);
like(
    $execution,
    qr/Transactions [ ] MUST [ ] remain [ ] short [ ] and [ ] deterministic/msx,
    'execution prompt preserves transaction discipline'
);
like(
    $execution,
    qr/What [ ] is [ ] canonical [ ] state[?]/msx,
    'execution prompt requires canonical-state review'
);
like(
    $execution,
    qr/Can [ ] this [ ] be [ ] rebuilt[?]/msx,
    'execution prompt requires rebuildability review'
);
like(
    $execution,
    qr/Can [ ] this [ ] be [ ] replayed[?]/msx,
    'execution prompt requires replayability review'
);
like(
    $readme,
    qr/Execution [ ] constitution [ ] is [ ] mandatory/msx,
    'README records execution constitution as a final decision'
);
like(
    $prompt_governance,
    qr/Prompt [ ] 50 [ ] alignment/msx,
    'prompt governance aligns with execution constitution'
);
like( $architecture, qr/prompt\/50[.]txt/msx,
    'executable architecture contract aligns with execution constitution' );
like(
    $engineering,
    qr/Prompt [ ] 50 [ ] alignment/msx,
    'engineering invariants prompt aligns with execution constitution'
);
like(
    $discipline,
    qr/Prompt [ ] 50 [ ] alignment/msx,
    'core discipline prompt aligns with execution constitution'
);
like(
    path('prompt/36.txt')->slurp,
    qr/Prompt [ ] 50 [ ] alignment/msx,
    'test strategy prompt aligns with execution constitution'
);
like(
    path('prompt/16.txt')->slurp,
    qr/Prompt [ ] 50 [ ] alignment/msx,
    'software engineering prompt aligns with execution constitution'
);

_check_scalability_prompt(
    {
        architecture => $architecture,
        engineering  => $engineering,
        execution    => $execution,
        readme       => $readme,
        scalability  => $scalability,
    }
);

_check_domain_integrity_prompt(
    {
        architecture     => $architecture,
        domain_integrity => $domain_integrity,
        engineering      => $engineering,
        execution        => $execution,
        readme           => $readme,
        scalability      => $scalability,
    }
);

_check_retrieval_prompt(
    {
        architecture     => $architecture,
        domain_integrity => $domain_integrity,
        engineering      => $engineering,
        execution        => $execution,
        readme           => $readme,
        retrieval        => $retrieval,
        scalability      => $scalability,
    }
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

sub _check_scalability_prompt {
    my ($context) = @_;

    my $scalability_text = $context->{scalability};

    like(
        $scalability_text,
        qr/Operational [ ] Scalability [ ] And [ ] Projection [ ] Stability/msx,
        'scalability prompt defines the new constitution'
    );
    like(
        $scalability_text,
        qr/It [ ] extends [ ] prompt\/50[.]txt/msx,
        'scalability prompt extends execution constitution'
    );
    ok(
        _has_all(
            $scalability_text, 'operationally predictable',
            'rebuildable',     'horizontally scalable',
        ),
        'scalability prompt defines operational objective'
    );
    ok(
        _has_all(
            $scalability_text,
            'thread view',
            'category listing',
            'search queries',
        ),
        'scalability prompt names forum hot paths'
    );
    like(
        $scalability_text,
        qr/Hot [ ] paths [ ] MUST [ ] minimize [ ] joins/msx,
        'scalability prompt constrains hot path joins'
    );
    like(
        $scalability_text,
        qr/All [ ] critical [ ] queries [ ] MUST [ ] be [ ] explainable/msx,
        'scalability prompt requires explainable queries'
    );
    like(
        $scalability_text,
        qr/N[+]1 [ ] queries/msx,
        'scalability prompt forbids N+1 queries'
    );
    ok(
        _has_all(
            $scalability_text,
            'partial indexes',
            'covering indexes',
            'BRIN indexes',
        ),
        'scalability prompt defines index topology'
    );
    like(
        $scalability_text,
        qr/Projection [ ] updates [ ] MUST [ ] be [ ] idempotent/msx,
        'scalability prompt requires idempotent projections'
    );
    like(
        $scalability_text,
        qr/Projection [ ] lag [ ] MUST [ ] be [ ] observable/msx,
        'scalability prompt requires projection lag visibility'
    );
    like(
        $scalability_text,
        qr/shadow [ ] rebuilds/msx,
        'scalability prompt supports blue/green projection rebuilds'
    );
    like(
        $scalability_text,
        qr/globally [ ] hot [ ] mutable [ ] rows/msx,
        'scalability prompt forbids hot mutable rows'
    );
    ok(
        _has_all(
            $scalability_text,
            '`event_log` is domain truth',
            '`outbox_messages` is delivery work',
        ),
        'scalability prompt separates event log and outbox'
    );
    like(
        $scalability_text,
        qr/Search [ ] remains [ ] PostgreSQL-native/msx,
        'scalability prompt preserves PostgreSQL-native search'
    );
    like(
        $scalability_text,
        qr/Search [ ] MUST [ ] NEVER [ ] become [ ] authoritative/msx,
        'scalability prompt forbids authoritative search'
    );
    ok(
        _has_all(
            $scalability_text, 'Caches MUST be disposable, bounded',
            'invalidation-aware',
        ),
        'scalability prompt preserves cache disposability'
    );
    like(
        $scalability_text,
        qr/Canonical [ ] forum [ ] operation [ ] MUST [ ] survive/msx,
        'scalability prompt requires graceful derived-system failure'
    );
    ok(
        _has_all(
            $scalability_text,
            'additive schema',
            'background backfill',
            'constraint enforcement',
        ),
        'scalability prompt defines online migration sequence'
    );
    ok(
        _has_all(
            $scalability_text,
            'projection lag',
            'dead letters',
            'queue depth',
        ),
        'scalability prompt defines operational observability'
    );
    like(
        $scalability_text,
        qr/What [ ] is [ ] the [ ] hot [ ] query[?]/msx,
        'scalability prompt requires hot-query review'
    );
    like(
        $scalability_text,
        qr/What [ ] is [ ] the [ ] operational [ ] recovery [ ] path[?]/msx,
        'scalability prompt requires operational recovery review'
    );
    ok(
        _has_all(
            $context->{readme},
            'Operational scalability and projection stability are mandatory',
        ),
        'README records scalability prompt as a final decision'
    );
    like(
        $context->{execution},
        qr/Prompt [ ] 51 [ ] alignment/msx,
        'execution constitution aligns with scalability prompt'
    );
    _check_prompt_51_alignment( 'prompt/3.txt',
        'database prompt aligns with scalability prompt' );
    _check_prompt_51_alignment( 'prompt/8.txt',
        'worker prompt aligns with scalability prompt' );
    _check_prompt_51_alignment( 'prompt/10.txt',
        'observability prompt aligns with scalability prompt' );
    _check_prompt_51_alignment( 'prompt/14.txt',
        'search prompt aligns with scalability prompt' );
    _check_prompt_51_alignment( 'prompt/15.txt',
        'performance prompt aligns with scalability prompt' );
    _check_prompt_51_alignment( 'prompt/40.txt',
        'multi-process prompt aligns with scalability prompt' );
    _check_prompt_51_alignment( 'prompt/41.txt',
        'profiling prompt aligns with scalability prompt' );
    like( $context->{architecture},
        qr/prompt\/51[.]txt/msx,
        'executable architecture prompt aligns with scalability prompt' );
    like(
        $context->{engineering},
        qr/Prompt [ ] 51 [ ] alignment/msx,
        'engineering invariants prompt aligns with scalability prompt'
    );

    return;
}

sub _check_prompt_51_alignment {
    my ( $prompt_file, $message ) = @_;

    like( path($prompt_file)->slurp,
        qr/Prompt [ ] 51 [ ] alignment/msx, $message );

    return;
}

sub _check_domain_integrity_prompt {
    my ($context) = @_;

    my $domain_text = $context->{domain_integrity};

    like(
        $domain_text,
        qr/Domain [ ] Integrity, [ ] Authorization [ ] And [ ] Moderation/msx,
        'domain integrity prompt defines the new constitution'
    );
    ok(
        _has_all(
            $domain_text,
            'permission-safe system',
            'moderation-safe system',
            'audit-safe system',
            'replay-safe system',
        ),
        'domain integrity prompt defines the safety objective'
    );
    like(
        $domain_text,
        qr/Canonical [ ] truth [ ] MUST [ ] remain [ ] in/msx,
        'domain integrity prompt preserves canonical truth'
    );
    like(
        $domain_text,
        qr/Authorization [ ] MUST [ ] remain [ ] explicit/msx,
        'domain integrity prompt requires explicit authorization'
    );
    ok(
        _has_all(
            $domain_text,
            'who can read?',
            'who can write?',
            'who can export?',
        ),
        'domain integrity prompt requires mandatory authorization questions'
    );
    like(
        $domain_text,
        qr/Visibility [ ] MUST [ ] remain [ ] explicit/msx,
        'domain integrity prompt requires explicit visibility'
    );
    like(
        $domain_text,
        qr/No [ ] restricted [ ] content [ ] may [ ] leak/msx,
        'domain integrity prompt forbids restricted content leakage'
    );
    like(
        $domain_text,
        qr/Moderation [ ] MUST [ ] remain [ ] server-authoritative/msx,
        'domain integrity prompt preserves server-authoritative moderation'
    );
    like(
        $domain_text,
        qr/Hard [ ] deletion [ ] MUST [ ] remain [ ] exceptional/msx,
        'domain integrity prompt restricts hard deletion'
    );
    ok(
        _has_all(
            $domain_text,
            'preserve historical revisions',
            'preserve edit attribution',
            'preserve moderation traceability',
        ),
        'domain integrity prompt preserves revision traceability'
    );
    ok(
        index( $domain_text,
            'All security-sensitive actions MUST create immutable audit records'
        ) >= 0,
        'domain integrity prompt requires immutable audit records'
    );
    ok(
        index( $domain_text,
            'All domain-significant workflows MUST emit events' ) >= 0,
        'domain integrity prompt requires domain events'
    );
    ok(
        _has_all( $domain_text, 'visibility_version', 'permission_version' ),
        'domain integrity prompt requires version-aware permission state'
    );
    like(
        $domain_text,
qr/Private [ ] or [ ] moderated [ ] content [ ] MUST [ ] NEVER [ ] leak/msx,
        'domain integrity prompt defines anti-leak discipline'
    );
    ok(
        index( $domain_text,
            'Search snippets MUST NOT expose restricted content' ) >= 0,
        'domain integrity prompt protects search snippets'
    );
    like(
        $domain_text,
        qr/Notification [ ] projections [ ] MUST [ ] remain [ ] derived/msx,
        'domain integrity prompt preserves notification derivation'
    );
    like(
        $domain_text,
        qr/Governance [ ] actions [ ] MUST [ ] remain [ ] explainable/msx,
        'domain integrity prompt requires explainable governance'
    );
    ok(
        _has_all(
            $domain_text,
            'deleted content is not publicly visible',
            'hidden posts do not appear in search',
            'suspended users cannot create content',
            'revoked sessions cannot authenticate',
        ),
        'domain integrity prompt defines domain invariants'
    );
    like(
        $domain_text,
        qr/What [ ] is [ ] canonical [ ] truth[?]/msx,
        'domain integrity prompt requires canonical truth review'
    );
    like(
        $domain_text,
        qr/What [ ] could [ ] leak[?]/msx,
        'domain integrity prompt requires anti-leak review'
    );
    like(
        $domain_text,
        qr/How [ ] is [ ] replay [ ] preserved[?]/msx,
        'domain integrity prompt requires replay preservation review'
    );
    ok(
        _has_all(
            $context->{readme},
'Domain integrity, authorization correctness, and moderation safety are mandatory',
        ),
        'README records domain integrity prompt as a final decision'
    );
    like( $context->{architecture},
        qr/prompt\/52[.]txt/msx,
        'executable architecture prompt aligns with domain integrity prompt' );
    like(
        $context->{engineering},
        qr/Prompt [ ] 52 [ ] alignment/msx,
        'engineering invariants prompt aligns with domain integrity prompt'
    );
    like(
        $context->{execution},
        qr/Prompt [ ] 52 [ ] alignment/msx,
        'execution constitution aligns with domain integrity prompt'
    );
    like(
        $context->{scalability},
        qr/Prompt [ ] 52 [ ] alignment/msx,
        'scalability prompt aligns with domain integrity prompt'
    );

    _check_prompt_52_alignment( 'prompt/5.txt',
        'security prompt aligns with domain integrity prompt' );
    _check_prompt_52_alignment( 'prompt/9.txt',
        'authorization prompt aligns with domain integrity prompt' );
    _check_prompt_52_alignment( 'prompt/13.txt',
        'domain model prompt aligns with domain integrity prompt' );
    _check_prompt_52_alignment( 'prompt/22.txt',
        'permission matrix prompt aligns with domain integrity prompt' );
    _check_prompt_52_alignment( 'prompt/23.txt',
        'event catalog prompt aligns with domain integrity prompt' );
    _check_prompt_52_alignment( 'prompt/24.txt',
        'HTTP workflow prompt aligns with domain integrity prompt' );
    _check_prompt_52_alignment( 'prompt/26.txt',
        'privacy prompt aligns with domain integrity prompt' );
    _check_prompt_52_alignment( 'prompt/31.txt',
        'admin console prompt aligns with domain integrity prompt' );
    _check_prompt_52_alignment( 'prompt/32.txt',
        'content policy prompt aligns with domain integrity prompt' );
    _check_prompt_52_alignment( 'prompt/34.txt',
        'SEO prompt aligns with domain integrity prompt' );

    return;
}

sub _check_prompt_52_alignment {
    my ( $prompt_file, $message ) = @_;

    like( path($prompt_file)->slurp,
        qr/Prompt [ ] 52 [ ] alignment/msx, $message );

    return;
}

sub _check_retrieval_prompt {
    my ($context) = @_;

    my $retrieval_text = $context->{retrieval};

    like(
        $retrieval_text,
        qr/Search, [ ] Feed, [ ] Syndication [ ] And [ ] Retrieval/msx,
        'retrieval prompt defines the new constitution'
    );
    ok(
        _has_all(
            $retrieval_text,
            'PostgreSQL-native retrieval platform',
            'permission-safe discovery system',
            'rebuildable indexing system',
            'moderation-safe syndication system',
        ),
        'retrieval prompt defines the retrieval objective'
    );
    ok(
        _has_all(
            $retrieval_text,    'Search and discovery MUST remain derived',
            'permission-aware', 'moderation-aware', 'operationally optional',
        ),
        'retrieval prompt keeps search and discovery derived'
    );
    like(
        $retrieval_text,
        qr/Canonical [ ] truth [ ] remains/msx,
        'retrieval prompt preserves canonical truth'
    );
    ok(
        _has_all(
            $retrieval_text,
            'Search indexes are derived projections',
            'RSS feeds are derived projections',
            'Autocomplete is derived',
            'Trending is derived',
            'Recommendations are derived',
        ),
        'retrieval prompt classifies retrieval surfaces as derived'
    );
    like(
        $retrieval_text,
        qr/Search [ ] MUST [ ] remain [ ] PostgreSQL-native/msx,
        'retrieval prompt preserves PostgreSQL-native search'
    );
    ok(
        _has_all(
            $retrieval_text,        'tsvector',
            'websearch_to_tsquery', 'GIN indexes',
            'pg_trgm',              'unaccent',
        ),
        'retrieval prompt names PostgreSQL search features'
    );
    like(
        $retrieval_text,
qr/Italian [ ] language [ ] support [ ] SHOULD [ ] remain [ ] first-class/msx,
        'retrieval prompt preserves Italian language support'
    );
    like(
        $retrieval_text,
        qr/Search [ ] projections [ ] MUST [ ] remain [ ] rebuildable/msx,
        'retrieval prompt requires rebuildable search projections'
    );
    ok(
        _has_all(
            $retrieval_text,    'entity_type',
            'permission_scope', 'search_vector',
            'source_version',   'visibility_version',
            'permission_version',
        ),
        'retrieval prompt defines search projection fields'
    );
    like(
        $retrieval_text,
qr/Search [ ] projections [ ] MUST [ ] NOT [ ] become [ ] authoritative/msx,
        'retrieval prompt forbids authoritative search projections'
    );
    ok(
        _has_all(
            $retrieval_text,
            'canonical write',
            'event_log append',
            'outbox message',
            'Minion indexing job',
            'projection update',
            'cache invalidation',
        ),
        'retrieval prompt defines indexing workflow'
    );
    like(
        $retrieval_text,
        qr/Indexing [ ] MUST [ ] remain [ ] asynchronous/msx,
        'retrieval prompt keeps indexing asynchronous'
    );
    like(
        $retrieval_text,
        qr/User-facing [ ] writes [ ] MUST [ ] NOT [ ] block/msx,
        'retrieval prompt prevents write path blocking on indexing'
    );
    ok(
        _has_all(
            $retrieval_text,
            'full rebuild',
            'targeted rebuild',
            'replay from event range',
            'resumable rebuild',
            'generation switching',
        ),
        'retrieval prompt defines rebuild discipline'
    );
    like(
        $retrieval_text,
qr/Search [ ] rebuild [ ] MUST [ ] NOT [ ] block [ ] canonical [ ] writes/msx,
        'retrieval prompt prevents rebuilds from blocking writes'
    );
    ok(
        _has_all(
            $retrieval_text,
            'generation_id',
            'inactive rebuild generation',
            'blue/green activation',
            'rollback activation',
        ),
        'retrieval prompt defines projection generations'
    );
    ok(
        _has_all(
            $retrieval_text,      'ts_rank',
            'title weighting',    'freshness',
            'category relevance', 'optional Perl-side ranking policy',
        ),
        'retrieval prompt defines ranking inputs'
    );
    like(
        $retrieval_text,
        qr/Ranking [ ] MUST [ ] remain [ ] explainable/msx,
        'retrieval prompt requires explainable ranking'
    );
    ok(
        _has_all(
            $retrieval_text,
            'opaque scoring',
            'nondeterministic ranking',
            'hidden personalization',
            'irreproducible results',
        ),
        'retrieval prompt rejects opaque ranking'
    );
    ok(
        _has_all(
            $retrieval_text,
            'Autocomplete SHOULD',
            'use pg_trgm where useful',
            'remain permission-aware',
            'remain rate-limited',
            'remain bounded',
        ),
        'retrieval prompt defines autocomplete discipline'
    );
    ok(
        _has_all(
            $retrieval_text,
            'Autocomplete MUST NEVER expose',
            'private content',
            'quarantined content',
            'inaccessible threads',
        ),
        'retrieval prompt forbids autocomplete leaks'
    );
    ok(
        _has_all(
            $retrieval_text,
            'Feeds MUST',
            'respect visibility',
            'respect moderation',
            'respect deletion',
            'support rebuildability',
        ),
        'retrieval prompt defines RSS and Atom safety'
    );
    ok(
        _has_all(
            $retrieval_text,
            'Feeds SHOULD',
            'expose excerpts by default',
            'avoid unsafe HTML',
            'remain rate-limited',
        ),
        'retrieval prompt defines feed ergonomics'
    );
    ok(
        _has_all(
            $retrieval_text,
            'Private or moderated content MUST NOT appear in',
            'OpenGraph',
            'Twitter cards',
            'sitemap entries',
            'syndication feeds',
        ),
        'retrieval prompt defines metadata anti-leak rules'
    );
    ok(
        _has_all(
            $retrieval_text,
            'Feed systems SHOULD remain derived projections',
            'Feed rebuild MUST remain possible',
        ),
        'retrieval prompt preserves derived feed systems'
    );
    ok(
        _has_all(
            $retrieval_text,
            'Trending systems MUST',
            'tolerate rebuild',
            'tolerate replay',
            'avoid abuse amplification',
        ),
        'retrieval prompt defines trending constraints'
    );
    ok(
        _has_all(
            $retrieval_text,
            'Search caches and feed caches remain optional acceleration',
            'be disposable',
            'remain permission-safe',
        ),
        'retrieval prompt preserves cache disposability'
    );
    like(
        $retrieval_text,
        qr/Restricted [ ] content [ ] MUST [ ] NEVER [ ] leak [ ] through/msx,
        'retrieval prompt defines restricted-content anti-leak rules'
    );
    ok(
        _has_all(
            $retrieval_text,
            'search latency',
            'projection lag',
            'rebuild progress',
            'indexing throughput',
            'feed generation latency',
        ),
        'retrieval prompt defines retrieval observability'
    );
    like(
        $retrieval_text,
        qr/What [ ] is [ ] canonical [ ] truth[?]/msx,
        'retrieval prompt requires canonical truth review'
    );
    like(
        $retrieval_text,
        qr/What [ ] happens [ ] if [ ] indexing [ ] fails[?]/msx,
        'retrieval prompt requires indexing failure review'
    );
    ok(
        _has_all(
            $context->{readme},
            'Search, feed, syndication, and retrieval safety are mandatory',
        ),
        'README records retrieval prompt as a final decision'
    );
    like( $context->{architecture},
        qr/prompt\/53[.]txt/msx,
        'executable architecture prompt aligns with retrieval prompt' );
    like(
        $context->{engineering},
        qr/Prompt [ ] 53 [ ] alignment/msx,
        'engineering invariants prompt aligns with retrieval prompt'
    );
    like(
        $context->{execution},
        qr/Prompt [ ] 53 [ ] alignment/msx,
        'execution constitution aligns with retrieval prompt'
    );
    like(
        $context->{scalability},
        qr/Prompt [ ] 53 [ ] alignment/msx,
        'scalability prompt aligns with retrieval prompt'
    );
    like(
        $context->{domain_integrity},
        qr/Prompt [ ] 53 [ ] alignment/msx,
        'domain integrity prompt aligns with retrieval prompt'
    );

    _check_prompt_53_alignment( 'prompt/10.txt',
        'observability prompt aligns with retrieval prompt' );
    _check_prompt_53_alignment( 'prompt/14.txt',
        'search prompt aligns with retrieval prompt' );
    _check_prompt_53_alignment( 'prompt/19.txt',
        'cache decision prompt aligns with retrieval prompt' );
    _check_prompt_53_alignment( 'prompt/30.txt',
        'email and notification prompt aligns with retrieval prompt' );
    _check_prompt_53_alignment( 'prompt/34.txt',
        'SEO prompt aligns with retrieval prompt' );
    _check_prompt_53_alignment( 'prompt/42.txt',
        'PostgreSQL-native search prompt aligns with retrieval prompt' );

    return;
}

sub _check_prompt_53_alignment {
    my ( $prompt_file, $message ) = @_;

    like( path($prompt_file)->slurp,
        qr/Prompt [ ] 53 [ ] alignment/msx, $message );

    return;
}

sub _has_all {
    my ( $text, @terms ) = @_;

    for my $term (@terms) {
        return 0 if index( $text, $term ) < 0;
    }

    return 1;
}

1;
