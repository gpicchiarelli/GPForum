package main;

use strict;
use warnings;

use Mojo::File qw(path);
use Test::Fatal;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Application::LayerMap;
use GPForum::Domain::EventEnvelope;
use GPForum::I18N::Namespace;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Jobs::EventPayload;
use GPForum::Query::ReadModel;
use GPForum::Security::BrowserHeaders;
use GPForum::Service::Outbox::MessageBuilder;
use GPForum::Test::Id;
use GPForum::Test::Schema;
use GPForum::Theme::Registry;
use GPForum::Web::RenderPolicy;

our $VERSION = '0.001';

subtest
  'domain event envelope keeps durable and transport contracts aligned' => sub {
    my $envelope = GPForum::Domain::EventEnvelope->new;
    my $event    = $envelope->record(
        actor_id          => 'user-1',
        aggregate_id      => 'post-1',
        aggregate_type    => 'post',
        aggregate_version => 2,
        causation_id      => 'event-parent',
        correlation_id    => 'correlation-1',
        event_id          => 'event-1',
        event_type        => 'post.created',
        metadata          => { request_id => 'request-1' },
        payload           => { thread_id  => 'thread-1' },
        schema_version    => 1,
        timestamp         => '2026-05-28T08:00:00Z',
    );

    is( $event->{schema_version}, 1, 'event record preserves schema version' );
    is( $event->{metadata}{event_id},
        'event-1', 'event metadata carries event id' );
    is( $event->{metadata}{actor}{id},
        'user-1', 'event metadata carries actor id' );
    is( $event->{metadata}{transport}{listen_notify_channel},
        'gpforum_domain_events',
        'event metadata prepares LISTEN/NOTIFY channel' );

    my $payload = $envelope->transport_payload($event);
    is( $payload->{contract},
        'gpforum.domain_event', 'transport payload names event contract' );
    is( $payload->{contract_version},
        1, 'transport payload versions event contract' );
    is( $payload->{event_type},
        'post.created', 'transport keeps legacy event_type field' );
    is( $payload->{domain_payload}{thread_id},
        'thread-1', 'transport keeps legacy domain_payload field' );
    is( $payload->{aggregate}{type},
        'post', 'transport exposes structured aggregate metadata' );
    is( $payload->{transport}{nats_subject},
        'gpforum.domain_events', 'transport prepares future NATS subject' );
  };

subtest 'target architecture namespaces are represented by code' => sub {
    my $layers = GPForum::Application::LayerMap->new;

    is( $layers->namespace_for('Application'),
        'GPForum::Application', 'application layer is named' );
    is( $layers->namespace_for('Query'),
        'GPForum::Query', 'query layer is named' );
    is( $layers->namespace_for('Jobs'),
        'GPForum::Jobs', 'jobs layer is named' );
    is( $layers->namespace_for('I18N'),
        'GPForum::I18N', 'i18n layer is named' );
};

subtest
  'event recorder appends event, outbox message, and audit through one boundary'
  => sub {
    my $schema   = GPForum::Test::Schema->new;
    my $recorder = GPForum::Infrastructure::EventRecorder->new(
        id_service => GPForum::Test::Id->new,
        schema     => $schema,
    );

    my $event = $recorder->record_event(
        actor_id       => 'user-1',
        aggregate_id   => 'thread-1',
        aggregate_type => 'thread',
        correlation_id => 'correlation-1',
        event_type     => 'thread.created',
        payload        => { category_id => 'category-1' },
        timestamp      => '2026-05-28T08:00:00Z',
    );
    my $first_audit = $recorder->record_audit(
        action         => 'thread.created',
        actor_id       => 'user-1',
        correlation_id => $event->{correlation_id},
        metadata       => { title => 'Welcome' },
        target_id      => 'thread-1',
        target_type    => 'thread',
    );

    is( scalar @{ $schema->created_for('EventLog') },
        1, 'recorder creates one event log row' );
    is( scalar @{ $schema->created_for('OutboxMessage') },
        1, 'recorder creates one outbox row' );
    is( scalar @{ $schema->created_for('AuditLog') },
        1, 'recorder creates one audit row' );
    is( $schema->created_for('OutboxMessage')->[0]{payload}{contract},
        'gpforum.domain_event', 'outbox row stores standard event contract' );
    is( $schema->created_for('AuditLog')->[0]{correlation_id},
        'correlation-1', 'audit correlation matches event correlation' );
    ok(
        length $first_audit->{record_hash},
        'audit record hash is computed by recorder'
    );
    is( $first_audit->{previous_hash},
        undef, 'first audit row has no previous hash' );

    my $second_audit = $recorder->record_audit(
        action         => 'thread.updated',
        actor_id       => 'user-1',
        correlation_id => $event->{correlation_id},
        metadata       => { title => 'Welcome back' },
        target_id      => 'thread-1',
        target_type    => 'thread',
    );
    is( scalar @{ $schema->created_for('AuditLog') },
        2, 'recorder creates a second audit row' );
    is(
        $second_audit->{previous_hash},
        $first_audit->{record_hash},
        'audit hash chain links to previous row'
    );
    isnt(
        $second_audit->{record_hash},
        $first_audit->{record_hash},
        'audit hash changes with record content'
    );
  };

subtest 'moderation write stores use the shared event recorder boundary' =>
  sub {
    for my $store (
        qw(
        ActionStore
        ReportStore
        SuspensionStore
        )
      )
    {
        my $source =
          path( 'lib/GPForum/Service/Moderation', "$store.pm" )->slurp;
        like(
            $source,
            qr/GPForum::Infrastructure::EventRecorder/msx,
            "$store depends on event recorder"
        );
        unlike( $source, qr/Outbox::MessageBuilder/msx,
            "$store does not build outbox messages directly" );
    }
  };

subtest 'privacy write stores use the shared event recorder boundary' => sub {
    for my $store (
        qw(
        DeletionWorkflow
        RetentionHoldStore
        )
      )
    {
        my $source = path( 'lib/GPForum/Service/Privacy', "$store.pm" )->slurp;

        like(
            $source,
            qr/GPForum::Infrastructure::EventRecorder/msx,
            "$store depends on event recorder"
        );
        unlike( $source, qr/Outbox::MessageBuilder/msx,
            "$store does not build outbox messages directly" );
    }
};

subtest 'portability export writes use the shared event recorder boundary' =>
  sub {
    my $source =
      path('lib/GPForum/Service/Portability/ExportBundleBuilder.pm')->slurp;

    like(
        $source,
        qr/GPForum::Infrastructure::EventRecorder/msx,
        'export bundle builder depends on event recorder'
    );
    unlike( $source, qr/Outbox::MessageBuilder/msx,
        'export bundle builder does not build outbox messages directly' );
  };

subtest 'attachment lifecycle writes use the shared event recorder boundary' =>
  sub {
    my $source = path('lib/GPForum/Service/Attachment/Store.pm')->slurp;

    like(
        $source,
        qr/GPForum::Infrastructure::EventRecorder/msx,
        'attachment store depends on event recorder'
    );
    unlike( $source, qr/Outbox::MessageBuilder/msx,
        'attachment store does not build outbox messages directly' );
    unlike(
        $source,
        qr/resultset\('EventLog'\)->create/msx,
        'attachment store does not write EventLog directly'
    );
    unlike(
        $source,
        qr/resultset\('OutboxMessage'\)->create/msx,
        'attachment store does not write OutboxMessage directly'
    );
  };

subtest 'admin role audit writes use the shared event recorder boundary' =>
  sub {
    for my $store (
        qw(
        RoleBindingStore
        RoleCatalog
        )
      )
    {
        my $source = path( 'lib/GPForum/Service/Admin', "$store.pm" )->slurp;

        like(
            $source,
            qr/GPForum::Infrastructure::EventRecorder/msx,
            "$store depends on event recorder"
        );
        unlike(
            $source,
            qr/resultset\('AuditLog'\)->create/msx,
            "$store does not write AuditLog directly"
        );
    }
  };

subtest 'service layer routes core event and audit writes through recorder' =>
  sub {
    my @files = grep { "$_" =~ /[.]pm\z/msx }
      path('lib/GPForum/Service')->list_tree->each;

    for my $file (@files) {
        my $source = $file->slurp;
        unlike(
            $source,
            qr/resultset\('(EventLog|OutboxMessage|AuditLog)'\)->create/msx,
            "$file does not write event, outbox, or audit rows directly"
        );
    }
  };

subtest 'outbox message builder preserves worker compatibility' => sub {
    my $builder = GPForum::Service::Outbox::MessageBuilder->new(
        id_service => GPForum::Test::Id->new, );
    my $message = $builder->for_event(
        {
            actor_id          => 'user-1',
            aggregate_id      => 'post-1',
            aggregate_type    => 'post',
            aggregate_version => 1,
            correlation_id    => 'correlation-1',
            event_id          => 'event-1',
            event_type        => 'post.created',
            idempotency_key   => 'post.created:post-1',
            metadata          => {},
            payload           => { thread_id => 'thread-1' },
            schema_version    => 1,
        }
    );

    is( $message->{queue}, 'events', 'outbox queue is unchanged' );
    is( $message->{job_type}, 'domain_event.dispatch',
        'outbox job type is unchanged' );
    is( $message->{payload}{event_type},
        'post.created', 'worker-compatible event_type remains top-level' );
    is( $message->{payload}{domain_payload}{thread_id},
        'thread-1', 'worker-compatible domain payload remains top-level' );
    is( $message->{payload}{metadata}{transport}{minion_job},
        'domain_event.dispatch', 'payload carries transport metadata' );
};

subtest 'job event payload normalizes structured envelopes for workers' => sub {
    my $payload = GPForum::Jobs::EventPayload->new->normalize(
        {
            actor     => { id => 'user-1' },
            aggregate => {
                id      => 'post-1',
                type    => 'post',
                version => 1,
            },
            event_type => 'post.created',
            payload    => { thread_id => 'thread-1' },
        }
    );

    is( $payload->{actor_id}, 'user-1', 'job payload exposes legacy actor id' );
    is( $payload->{aggregate_id},
        'post-1', 'job payload exposes legacy aggregate id' );
    is( $payload->{domain_payload}{thread_id},
        'thread-1', 'job payload exposes legacy domain payload' );
};

subtest 'browser security headers are testable outside bootstrap' => sub {
    my $headers = GPForum::Security::BrowserHeaders->new;
    my $csp     = $headers->content_security_policy;

    like( $csp, qr/default-src [ ] 'self'/msx, 'CSP keeps default-src self' );
    like( $csp, qr/script-src [ ] 'self'/msx,  'CSP declares script source' );
    like( $csp, qr/style-src [ ] 'self'/msx,   'CSP declares style source' );
    like( $csp, qr/object-src [ ] 'none'/msx,  'CSP forbids object content' );
};

subtest 'SSR render policy centralizes raw HTML decisions' => sub {
    my $policy = GPForum::Web::RenderPolicy->new;

    is(
        $policy->trusted_html(
            context => 'search.snippet',
            html    => '<mark>Forum</mark>',
        ),
        '<mark>Forum</mark>',
        'trusted search snippets can pass through the policy'
    );
    like(
        exception {
            $policy->trusted_html(
                context => 'unknown',
                html    => '<script>alert(1)</script>',
            );
        },
        qr/untrusted [ ] html [ ] context/msx,
        'unknown raw HTML contexts are rejected'
    );
    is(
        $policy->attribute( name => 'aria-label', value => 'A&B' ),
        ' aria-label="A&amp;B"',
        'attribute helper escapes values'
    );
};

subtest 'theme registry exposes explicit theme contracts' => sub {
    my $registry = GPForum::Theme::Registry->new;

    is_deeply(
        $registry->supported_themes,
        [qw(default dark high_contrast)],
        'theme registry names default, dark, and high contrast themes'
    );
    ok( $registry->supported('dark'), 'dark theme is supported' );
    is( $registry->theme_color('unknown'),
        '#f8f6ef', 'unknown theme falls back safely to default color' );
    is( $registry->theme('high_contrast')->{foreground},
        '#000000', 'high contrast theme exposes readable foreground token' );
    is( $registry->color_scheme('dark'),
        'dark', 'dark theme exposes browser color scheme metadata' );
    is( $registry->token( 'default', 'primary' ),
        '#214237', 'theme registry exposes semantic tokens by name' );
    is_deeply(
        [ map { $_->[0] } @{ $registry->css_variables('default') } ],
        [ map { "color-$_" =~ s/_/-/gr } @{ $registry->token_names } ],
        'theme registry exports CSS variable names for every token'
    );
    is( $registry->theme_options('dark')->[1]{current},
        1, 'theme options mark the current theme' );
};

subtest 'i18n namespace helper validates translation key discipline' => sub {
    my $namespace = GPForum::I18N::Namespace->new;

    ok( $namespace->valid_key('nav.home'), 'namespaced key is valid' );
    is( $namespace->namespace_for('moderation.report_post'),
        'moderation', 'namespace can be extracted from key' );
    ok(
        !$namespace->valid_key('Missing Key'),
        'free text is not a valid translation key'
    );
};

subtest 'query read model provides isolated hash copies' => sub {
    my $read_model =
      GPForum::Query::ReadModel->new( data => { title => 'Welcome' } );
    my $copy = $read_model->as_hash;
    $copy->{title} = 'Changed';

    is( $read_model->value('title'),
        'Welcome', 'read model keeps internal data isolated' );
};

done_testing();
