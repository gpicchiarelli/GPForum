package main;

use strict;
use warnings;

use Scalar::Util qw(blessed);
use Test::More;

use lib 'lib';

use GPForum::Service::I18N;
use GPForum::Service::Notification::Renderer;
use GPForum::ViewModel::Admin::Presenter;
use GPForum::ViewModel::Attachment::Presenter;
use GPForum::ViewModel::Community::Presenter;
use GPForum::ViewModel::Discovery::Presenter;
use GPForum::ViewModel::Forum::Presenter;
use GPForum::ViewModel::Identity::Presenter;
use GPForum::ViewModel::Moderation::Presenter;
use GPForum::ViewModel::Notifications::Presenter;
use GPForum::ViewModel::Privacy::Presenter;

our $VERSION = '0.001';

my $forum = GPForum::ViewModel::Forum::Presenter->new;

my $category = $forum->category(
    _row(
        {
            category_id => 'category-1',
            description => 'General discussion',
            position    => 1,
            slug        => 'general',
            title       => 'General',
            visibility  => 'public',
        }
    )
);
is_deeply(
    $category,
    {
        category_id => 'category-1',
        description => 'General discussion',
        position    => 1,
        slug        => 'general',
        title       => 'General',
        ui          => { heading_id => 'category-category-1-heading', },
        visibility  => 'public',
    },
'forum category presenter keeps existing fields and adds semantic UI metadata'
);

my $post = $forum->post(
    _row(
        {
            author_display_name => 'Giacomo',
            author_user_id      => 'user-1',
            author_username     => 'giacomo',
            moderation_state    => 'visible',
            position            => 2,
            post_id             => 'post-2',
            thread_id           => 'thread-1',
            visibility          => 'public',
        },
        current_body => _row( { body_rendered_safe => '<p>Rendered</p>' } ),
    )
);
is( $post->{body}, '<p>Rendered</p>',
    'forum post presenter reads safe rendered body from relation' );
is( $post->{author_profile_label},
    '@giacomo', 'forum post presenter prepares public profile label' );
is( $post->{ui}{permalink},
    'post-post-2', 'forum post presenter prepares permalink metadata' );

my $autocomplete = $forum->autocomplete_suggestion(
    {
        entity_id       => 'thread-1',
        entity_type     => 'thread',
        title           => 'Welcome',
        body            => 'body must not be serialized in autocomplete',
        visibility      => 'public',
        author_username => 'giacomo',
    }
);
ok( !exists $autocomplete->{body},
    'autocomplete presenter omits body from serialized suggestions' );
is( $autocomplete->{author_profile_label},
    '@giacomo', 'autocomplete presenter keeps author profile label' );
is_deeply(
    $forum->created_thread_response(
        { thread => { thread_id => 'thread-1' } }
    ),
    { status => 'created', thread_id => 'thread-1' },
    'forum presenter owns created-thread response shape'
);
is_deeply(
    $forum->created_post_response( { post => { post_id => 'post-1' } } ),
    { post_id => 'post-1', status => 'created' },
    'forum presenter owns created-post response shape'
);
is_deeply(
    $forum->read_marker_response(
        {
            read_state => { thread_id => 'thread-1', last_read_post_id => 'p1' }
        }
    ),
    {
        read_state => { thread_id => 'thread-1', last_read_post_id => 'p1' },
        status     => 'ok',
    },
    'forum presenter owns read-marker response shape'
);
is(
    $forum->report_response( { report_id => 'report-1' } )->{report}{report_id},
    'report-1',
    'forum presenter owns report response shape'
);

my $reading = $forum->reading_summary(
    posts      => [ { post_id => 'post-1' } ],
    read_state => GPForum::Test::ViewModelReadState->new,
    thread_id  => 'thread-1',
    user_id    => 'user-1',
);
is( $reading->{first_unread_anchor},
    'post-post-1', 'reading summary is delegated through the view model' );
is_deeply(
    $forum->reading_summary(
        posts      => [],
        read_state => GPForum::Test::ViewModelReadState->new,
        thread_id  => 'thread-1',
    ),
    { authenticated => 0 },
    'reading summary remains anonymous-safe without a user'
);

my $engagement = $forum->engagement_summary(
    bookmark_store     => GPForum::Test::ViewModelEngagementStore->new,
    subscription_store => GPForum::Test::ViewModelEngagementStore->new,
    thread             => { thread_id => 'thread-1' },
    user_id            => 'user-1',
);
ok( $engagement->{authenticated},
    'engagement summary marks authenticated user' );
ok(
    $engagement->{bookmark}{bookmarked},
    'engagement summary shapes bookmark status'
);

my $new_thread_form = $forum->new_thread_form(
    categories => [
        {
            category_id => 'category-1',
            title       => 'General',
            visibility  => 'public',
        },
    ],
    command_id => 'thread-command-1',
    errors     => {
        body_source => 'body is required',
        title       => 'title is required',
    },
    values => {
        body_source => q{},
        category_id => 'category-1',
        title       => q{},
    },
);
is( $new_thread_form->{ui}{described_by},
    'thread-error-summary',
    'forum new-thread presenter prepares error summary relationship' );
is( $new_thread_form->{fields}[0],
    'category_id',
    'forum new-thread presenter preserves JSON field-name compatibility' );
is( $new_thread_form->{command_id},
    'thread-command-1', 'forum new-thread presenter carries command id' );
is(
    $new_thread_form->{form_fields}[1]{error_attrs},
    ' aria-invalid="true" aria-describedby="thread-title-error"',
    'forum new-thread presenter prepares title error attributes'
);
is( $new_thread_form->{form_fields}[2]{error_id},
    'thread-body-error', 'forum new-thread presenter prepares body error id' );
is( $new_thread_form->{form_fields}[3]{value},
    'public', 'forum new-thread presenter defaults visibility' );
is_deeply(
    $new_thread_form->{error_fields},
    [
        { id => 'thread-category',   name => 'category_id' },
        { id => 'thread-title',      name => 'title' },
        { id => 'thread-body',       name => 'body_source' },
        { id => 'thread-visibility', name => 'visibility' },
    ],
    'forum new-thread presenter prepares error summary field metadata'
);

my $admin = GPForum::ViewModel::Admin::Presenter->new;
is_deeply(
    $admin->categories_page(
        categories => [
            {
                category_id => 'category 1',
                slug        => 'general',
                title       => 'General',
                visibility  => 'public',
            }
        ],
        csrf_token => 'csrf-1',
    )->{categories}[0]{ui},
    { heading_id => 'category-category-1-heading' },
    'admin categories page prepares category heading metadata'
);
is(
    $admin->category_response( 'category_created', { title => 'General' } )
      ->{status},
    'category_created',
    'admin category response keeps the write status'
);
is(
    $admin->stable_id( 'admin-user', 'bad value/1', 'heading' ),
    'admin-user-bad-value-1-heading',
    'base presenter builds safe stable HTML ids'
);
my $audit = $admin->audit_entry(
    {
        action         => 'admin.role_bound',
        actor_id       => 'admin-1',
        audit_id       => 'audit-1',
        correlation_id => 'corr-1',
        created_at     => '2026-05-23T12:00:00Z',
        metadata       => { reason => 'least privilege', tags => ['rbac'] },
        target_id      => 'role-1',
        target_type    => 'role',
    }
);
is( $audit->{metadata_items}[0]{name},
    'reason', 'admin audit metadata is sorted for stable SSR rendering' );
is( $audit->{metadata_items}[1]{value},
    '["rbac"]', 'admin audit metadata values are JSON encoded consistently' );
is( $audit->{ui}{heading_id},
    'audit-audit-1-heading', 'admin audit exposes semantic heading metadata' );

my $admin_user = $admin->user(
    _row(
        {
            created_at       => '2026-05-23T12:00:00Z',
            display_name     => 'Admin User',
            email_normalized => 'admin@example.test',
            id               => 'user 1',
            status           => 'active',
            trust_level      => 3,
            username         => 'admin_user',
        }
    )
);
is( $admin_user->{ui}{heading_id},
    'admin-user-user-1-heading',
    'admin user presenter normalizes heading metadata from row objects' );
is_deeply(
    $admin->users_page( users => [ { id => 'user-2', username => 'second' } ] )
      ->{users}[0]{ui},
    {
        audit_link_target_type => 'user',
        heading_id             => 'admin-user-user-2-heading',
    },
    'admin users page shapes plain hashes through presenter'
);

my $jobs_page = $admin->jobs_page(
    jobs => {
        dead_letters =>
          [ { dead_letter_id => 'dead-letter 1', error_class => 'failed' } ],
        outbox_messages =>
          [ { outbox_id => 'outbox 1', job_type => 'notification.dispatch' } ],
    }
);
is( $jobs_page->{jobs}{outbox_messages}[0]{ui}{heading_id},
    'outbox-outbox-1-heading',
    'admin jobs page prepares outbox heading metadata' );
is(
    $jobs_page->{jobs}{dead_letters}[0]{ui}{heading_id},
    'dead-letter-dead-letter-1-heading',
    'admin jobs page prepares dead-letter heading metadata'
);

my $status_page = $admin->status_page(
    admin_status => {
        benchmark          => { status  => 'manual' },
        metrics            => { runtime => { mode => 'test' } },
        query_budget_drift => { status  => 'ok' },
        query_budgets      => {
            endpoints => {
                admin_status => { max_queries => 6 },
                admin_jobs   => { max_queries => 4 },
            },
        },
        readiness => { status => 'ok' },
    }
);
is( $status_page->{admin_status}{readiness}{status},
    'ok', 'admin status page preserves raw JSON compatibility payload' );
is( $status_page->{query_budget_rows}[0]{endpoint},
    'admin_jobs', 'admin status presenter sorts query budget rows' );
is( $status_page->{query_budget_rows}[0]{ui}{row_id},
    'query-budget-admin_jobs',
    'admin status presenter prepares stable row metadata' );
is_deeply(
    $admin->role_response(
        'role_created', { role_id => 'role-1', name => 'space_admin' }
    ),
    {
        role => {
            created_at  => undef,
            description => undef,
            name        => 'space_admin',
            role_id     => 'role-1',
            ui          => { heading_id => 'role-role-1-heading' },
        },
        status => 'role_created',
    },
    'admin presenter owns role mutation response shape'
);
is(
    $admin->permission_response(
        'permission_created',
        {
            action        => 'view',
            permission_id => 'permission-1',
            resource_type => 'admin_console',
        }
    )->{permission}{ui}{heading_id},
    'permission-permission-1-heading',
    'admin presenter owns permission mutation response metadata'
);
is(
    $admin->role_binding_response( 'role_bound',
        { binding => { binding_id => 'binding 1', role_id => 'role-1' } } )
      ->{binding}{ui}{heading_id},
    'binding-binding-1-heading',
    'admin presenter owns role binding mutation response metadata'
);

my $moderation = GPForum::ViewModel::Moderation::Presenter->new;
my $action     = $moderation->moderation_action(
    {
        action => {
            action_type          => 'post.hidden',
            actor_user_id        => 'moderator-1',
            moderation_action_id => 'action-1',
            reason               => 'spam',
            target_id            => 'post-1',
            target_type          => 'post',
        },
    }
);
is( $action->{ui}{heading_id},
    'action-action-1-heading', 'moderation action exposes heading metadata' );
is(
    $action->{ui}{reverse_reason_id},
    'action-action-1-reverse-reason',
    'moderation action exposes reverse form control metadata'
);
ok( $action->{ui}{reversible},
    'moderation action marks unreversed actions as reversible for templates' );
is_deeply(
    $moderation->moderation_action_response(
        'post_hidden', { action => { moderation_action_id => 'action-1' } }
    ),
    {
        action => {
            action_type          => undef,
            actor_user_id        => undef,
            created_at           => undef,
            metadata             => undef,
            moderation_action_id => 'action-1',
            reason               => undef,
            reversed_at          => undef,
            reversed_by_user_id  => undef,
            target_id            => undef,
            target_type          => undef,
            ui                   => {
                heading_id         => 'action-action-1-heading',
                restore_reason_id  => 'action-action-1-restore-reason',
                reverse_heading_id => 'action-action-1-reverse-heading',
                reverse_reason_id  => 'action-action-1-reverse-reason',
                reversible         => 1,
                unlock_reason_id   => 'action-action-1-unlock-reason',
            },
        },
        status => 'post_hidden',
    },
    'moderation presenter owns action mutation response shape'
);
my $report = $moderation->report(
    {
        report_id   => 'report 1',
        target_id   => 'post-1',
        target_type => 'post',
    }
);
is( $report->{ui}{heading_id},
    'report-report-1-heading',
    'moderation report normalizes heading metadata' );
is( $report->{ui}{post_reason_id},
    'report-report-1-post-reason',
    'moderation report exposes post reason control metadata' );
is(
    $moderation->report_action_response( 'report_assigned', $report )
      ->{report}{ui}{heading_id},
    'report-report-1-heading',
    'moderation presenter owns report mutation response metadata'
);
my $suspension = $moderation->suspension(
    {
        suspension => {
            suspension_id => 'suspension 1',
            user_id       => 'user-1',
        },
    }
);
is(
    $suspension->{ui}{revoke_reason_id},
    'suspension-suspension-1-revoke-reason',
    'moderation suspension exposes revoke reason control metadata'
);
is(
    $moderation->suspension_response( 'user_suspended', $suspension )
      ->{suspension}{ui}{heading_id},
    'suspension-suspension-1-heading',
    'moderation presenter owns suspension mutation response metadata'
);

my $community = GPForum::ViewModel::Community::Presenter->new;
my $renderer  = GPForum::Service::Notification::Renderer->new(
    i18n => GPForum::Service::I18N->new );
is_deeply(
    $community->bookmark_response(
        'bookmarked', { bookmark_id => 'bookmark-1', target_id => 'thread-1' },
    ),
    {
        bookmark => { bookmark_id => 'bookmark-1', target_id => 'thread-1' },
        status   => 'bookmarked',
    },
    'community presenter owns bookmark mutation response shape'
);
is_deeply(
    $community->subscription_response(
        'followed',
        { subscription_id => 'subscription-1', target_id => 'thread-1' },
    ),
    {
        status       => 'followed',
        subscription => {
            subscription_id => 'subscription-1',
            target_id       => 'thread-1',
        },
    },
    'community presenter owns subscription mutation response shape'
);
my $notifications    = GPForum::ViewModel::Notifications::Presenter->new;
my $notification_row = {
    created_at        => '2026-05-23T12:00:00Z',
    notification_id   => 'notification-1',
    notification_type => 'mention',
    payload           => { thread_id => 'thread-1' },
    recipient_user_id => 'user-1',
    source_id         => 'post-1',
    source_type       => 'post',
};
my $notification = $notifications->notification(
    $notification_row,
    locale   => 'it',
    renderer => $renderer,
);
is(
    $notification->{presentation}{title},
    'Sei stato menzionato',
    'notification presenter renders locale-aware title'
);
is(
    $notification->{presentation}{email}{subject},
    'Sei stato menzionato su GPForum',
    'notification presenter renders locale-aware email subject'
);
is(
    $notification->{ui}{heading_id},
    'notification-notification-1-heading',
    'notification presenter exposes stable heading metadata'
);
is_deeply(
    $notifications->mark_read_response(
        {
            notification_id => 'notification-1',
            unread_count    => 2,
        }
    ),
    {
        read => {
            notification_id => 'notification-1',
            unread_count    => 2,
        },
        status       => 'read',
        unread_count => 2,
    },
    'notification presenter owns mark-read mutation response shape'
);
is_deeply(
    $community->notification(
        $notification_row,
        locale   => 'it',
        renderer => $renderer,
    ),
    $notification,
    'community presenter keeps notification compatibility delegate'
);

my $mention = $notifications->mention(
    {
        actor_display_name => 'Reply Author',
        actor_id           => 'user-2',
        actor_username     => 'reply_author',
        created_at         => '2026-05-23T12:00:00Z',
        mention_id         => 'mention-1',
        mentioned_user_id  => 'user-1',
        mentioned_username => 'giacomo',
        source_id          => 'post-1',
        source_type        => 'post',
    },
    locale   => 'en',
    renderer => $renderer,
);
is( $mention->{actor_profile_label},
    '@reply_author', 'mention presenter prepares actor profile label' );
is( $mention->{presentation}{by_label},
    'Mention by', 'mention presenter renders locale-aware presentation' );
is( $mention->{ui}{heading_id},
    'mention-mention-1-heading',
    'mention presenter exposes stable heading metadata' );

my $identity = GPForum::ViewModel::Identity::Presenter->new;
my $login    = $identity->login_form(
    errors => { identifier => 'identifier is required' },
    values => { identifier => q{} },
);
is( $login->{ui}{described_by},
    'login-error-summary', 'identity presenter prepares form error metadata' );
is(
    $login->{fields}[0]{error_attrs},
    ' aria-invalid="true" aria-describedby="login-identifier-error"',
    'identity presenter prepares login field error attributes'
);
is_deeply(
    $login->{error_fields},
    [
        { id => 'login-identifier', name => 'identifier' },
        { id => 'login-password',   name => 'password' },
    ],
    'identity presenter prepares login error summary field metadata'
);
my $general_login = $identity->login_form(
    errors => { login => 'login request could not be accepted' } );
is( $general_login->{ui}{described_by},
    'login-form-error',
    'identity presenter points general login errors at inline alert' );
my $register = $identity->register_form(
    errors => { email => 'email format is invalid' },
    values => { email => 'Raw@Example.TEST' },
);
is( $register->{fields}[2]{value}, 'Raw@Example.TEST',
'identity presenter falls back to raw email value when normalized value is absent'
);
is( $register->{fields}[2]{error_id},
    'register-email-error',
    'identity presenter prepares register field error id' );

my $profile = $identity->profile(
    {
        counts  => {},
        replies => { items => [] },
        threads => { items => [] },
        trust   => {},
        user    => { username => 'giacomo', display_name => 'Giacomo' },
    }
);
is( $profile->{user}{profile_label},
    '@giacomo', 'identity presenter fills safe public profile label' );
my $settings = $identity->settings_page(
    digest_frequency_options => [ { value   => 'daily' } ],
    locale_options           => [ { locale  => 'en' } ],
    notification_preferences => [ { channel => 'in_app' } ],
    theme_options            => [ { name    => 'default' } ],
);
is( $settings->{ui}{heading_id},
    'settings-heading',
    'identity presenter exposes settings heading metadata' );
is( $settings->{notification_preferences}[0]{channel},
    'in_app', 'identity presenter preserves settings preference payloads' );
_assert_no_blessed_values( $profile,
    'identity profile view model is plain data' );
_assert_no_blessed_values( $settings,
    'identity settings view model is plain data' );
_assert_no_blessed_values( $post, 'forum post view model is plain data' );

my $privacy = GPForum::ViewModel::Privacy::Presenter->new;
my $export  = $privacy->export_request(
    {
        export_request_id => 'export-1',
        manifest          => { counts => { posts => 2 } },
        status            => 'completed',
        subject_user_id   => 'user-1',
    }
);
is( $export->{manifest}{counts}{posts},
    2, 'privacy presenter keeps export manifest serialization stable' );
is( $export->{ui}{heading_id},
    'export-export-1-heading',
    'privacy export presenter exposes stable heading metadata' );
my $deletion = $privacy->deletion_request(
    {
        deletion_request_id => 'delete 1',
        status              => 'pending',
    }
);
is( $deletion->{ui}{heading_id},
    'deletion-delete-1-heading',
    'privacy deletion presenter normalizes heading metadata' );
is(
    $privacy->export_request_response( 'export_requested', $export )
      ->{export_request}{ui}{heading_id},
    'export-export-1-heading',
    'privacy presenter owns export mutation response metadata'
);
is(
    $privacy->deletion_request_response( 'deletion_requested', $deletion )
      ->{deletion_request}{ui}{heading_id},
    'deletion-delete-1-heading',
    'privacy presenter owns deletion mutation response metadata'
);
is_deeply(
    $privacy->deletion_review_response(
        'deletion_approved', { ok => 1, request_id => 'delete-1' }
    ),
    {
        deletion_review => {
            error      => undef,
            idempotent => 0,
            job        => undef,
            ok         => 1,
            request_id => 'delete-1',
        },
        status => 'deletion_approved',
    },
    'privacy presenter owns deletion review mutation response shape'
);

my $attachment_presenter = GPForum::ViewModel::Attachment::Presenter->new;
my $attachment           = $attachment_presenter->attachment(
    {
        attachment_id     => 'attachment-1',
        byte_size         => 512,
        media_type        => 'text/plain',
        original_filename => 'note.txt',
        scan_status       => 'clean',
        state             => 'ready',
    },
    download_url => '/attachments/attachment-1/download',
);
is(
    $attachment->{download_url},
    '/attachments/attachment-1/download',
    'attachment presenter keeps download URL presentation outside controller'
);
is(
    $attachment->{ui}{heading_id},
    'attachment-attachment-1-heading',
    'attachment presenter exposes stable heading metadata'
);
is_deeply(
    $attachment_presenter->upload_response(
        {
            attachment => {
                attachment_id     => 'attachment-1',
                byte_size         => 512,
                media_type        => 'text/plain',
                original_filename => 'note.txt',
            },
            link => { target_id => 'post-1' },
        },
        download_url => '/attachments/attachment-1/download',
    ),
    {
        attachment => {
            attachment_id     => 'attachment-1',
            byte_size         => 512,
            download_url      => '/attachments/attachment-1/download',
            media_type        => 'text/plain',
            original_filename => 'note.txt',
            scan_status       => undef,
            state             => undef,
            ui                => {
                heading_id => 'attachment-attachment-1-heading',
            },
        },
        link   => { target_id => 'post-1' },
        status => 'uploaded',
    },
    'attachment presenter owns upload mutation response shape'
);

my $resource = GPForum::ViewModel::Discovery::Presenter->new->resource(
    GPForum::Test::ViewModelDiscoveryRow->new );
is( $resource->{slug}, 'welcome',
    'discovery presenter serializes resource rows for sitemap/feed' );
is( $resource->{ui}{heading_id},
    'discovery-thread-1-heading',
    'discovery presenter adds semantic metadata without leaking row objects' );

done_testing();

sub _row {
    return GPForum::Test::ViewModelRow->new(@_);
}

sub _assert_no_blessed_values {
    my ( $value, $message ) = @_;

    my $found = _find_blessed($value);
    ok( !$found, $message );

    return;
}

sub _find_blessed {
    my ($value) = @_;

    return 1 if blessed($value);
    if ( ref $value eq 'HASH' ) {
        for my $child ( values %{$value} ) {
            return 1 if _find_blessed($child);
        }
    }
    if ( ref $value eq 'ARRAY' ) {
        for my $child ( @{$value} ) {
            return 1 if _find_blessed($child);
        }
    }

    return 0;
}

package GPForum::Test::ViewModelRow;

sub new {
    my ( $class, $columns, %related ) = @_;

    return bless { columns => $columns || {}, related => \%related }, $class;
}

sub get_column {
    my ( $self, $name ) = @_;

    return $self->{columns}{$name};
}

sub current_body {
    my ($self) = @_;

    return $self->{related}{current_body};
}

package GPForum::Test::ViewModelReadState;

sub new {
    my ($class) = @_;

    return bless {}, $class;
}

sub summary_for_page {
    return {
        authenticated         => 1,
        first_unread_anchor   => 'post-post-1',
        last_visible_position => 2,
    };
}

package GPForum::Test::ViewModelEngagementStore;

sub new {
    my ($class) = @_;

    return bless {}, $class;
}

sub status_for_user_target {
    my ( undef, undef, $target_type ) = @_;

    return { bookmarked => 1 } if $target_type eq 'thread';

    return { muted => 0, subscribed => 1 };
}

package GPForum::Test::ViewModelDiscoveryRow;

sub new {
    my ($class) = @_;

    return bless {
        category_id => 'category-1',
        slug        => 'welcome',
        thread_id   => 'thread-1',
        title       => 'Welcome',
    }, $class;
}

sub columns {
    return qw(category_id slug thread_id title);
}

sub get_column {
    my ( $self, $name ) = @_;

    return $self->{$name};
}

1;
