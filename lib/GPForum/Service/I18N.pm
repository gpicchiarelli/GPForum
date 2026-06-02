package GPForum::Service::I18N;

use strict;
use warnings;
use utf8;

use Const::Fast;
use Mojo::Base -base;
use POSIX qw(strftime);

our $VERSION = '0.001';

const my $FALLBACK_LOCALE => 'en';
const my $DEFAULT_QUALITY => 1;
const my $ZERO_QUALITY    => 0;

has default_locale     => sub { return $FALLBACK_LOCALE; };
has catalogs           => sub { return _default_catalogs(); };
has missing_key_logger => undef;

sub supported_locales {
    my ($self) = @_;

    return [ sort keys %{ $self->catalogs } ];
}

sub locale_registry {
    my ($self) = @_;

    my $registry     = _metadata_registry();
    my %supported    = map { $_ => 1 } @{ $self->supported_locales };
    my %metadata_for = map { $_ => { %{ $registry->{$_} } } }
      grep { $supported{$_} } keys %{$registry};

    return \%metadata_for;
}

sub negotiate {
    my ( $self, $accept_language ) = @_;

    my $default_locale = $self->_safe_default_locale;
    my %supported      = map { $_ => 1 } @{ $self->supported_locales };

    for my $range ( _language_ranges($accept_language) ) {
        return $default_locale if $range->{tag} eq '*';

        my $locale = _supported_locale( $range->{tag}, \%supported );
        return $locale if defined $locale;
    }

    return $default_locale;
}

sub supported_locale {
    my ( $self, $locale ) = @_;

    my %supported = map { $_ => 1 } @{ $self->supported_locales };

    return _supported_locale( _normalize_locale($locale), \%supported );
}

sub translate {
    my ( $self, $locale, $key, $variables ) = @_;

    $variables ||= {};

    my $catalogs  = $self->catalogs;
    my %supported = map { $_ => 1 } @{ $self->supported_locales };
    my $normalized_locale =
      _supported_locale( _normalize_locale($locale), \%supported ) || q{};
    my $message = _catalog_message( $catalogs, $normalized_locale, $key );

    if ( !defined $message && $normalized_locale ne $FALLBACK_LOCALE ) {
        $self->_log_missing_key( $normalized_locale, $key, 'fallback' );
        $message = _catalog_message( $catalogs, $FALLBACK_LOCALE, $key );
    }

    if ( !defined $message || ref $message ne q{} ) {
        $self->_log_missing_key( $normalized_locale || $FALLBACK_LOCALE,
            $key, 'missing' );
        return $key;
    }

    return _interpolate( $message, $variables );
}

sub translate_count {
    my ( $self, $locale, $key, $count, $variables ) = @_;

    $variables ||= {};
    $variables->{count} = $count;

    my $catalogs  = $self->catalogs;
    my %supported = map { $_ => 1 } @{ $self->supported_locales };
    my $normalized_locale =
      _supported_locale( _normalize_locale($locale), \%supported ) || q{};
    my $category = $self->plural_category( $normalized_locale, $count );
    my $message =
      _plural_message( _catalog_message( $catalogs, $normalized_locale, $key ),
        $category );

    if ( !defined $message && $normalized_locale ne $FALLBACK_LOCALE ) {
        $self->_log_missing_key( $normalized_locale, $key, 'fallback' );
        $message = _plural_message(
            _catalog_message( $catalogs, $FALLBACK_LOCALE, $key ),
            $self->plural_category( $FALLBACK_LOCALE, $count )
        );
    }

    if ( !defined $message ) {
        $self->_log_missing_key( $normalized_locale || $FALLBACK_LOCALE,
            $key, 'missing' );
        return $key;
    }

    return _interpolate( $message, $variables );
}

sub plural_category {
    my ( $self, $locale, $count ) = @_;

    return $count == 1 ? 'one' : 'other';
}

sub locale_metadata {
    my ( $self, $locale ) = @_;

    my %supported = map { $_ => 1 } @{ $self->supported_locales };
    my $safe_locale =
      _supported_locale( _normalize_locale($locale), \%supported )
      || $self->_safe_default_locale;
    my $metadata = _metadata_for($safe_locale);

    return { %{$metadata} };
}

sub direction {
    my ( $self, $locale ) = @_;

    return $self->locale_metadata($locale)->{direction};
}

sub format_date {
    my ( $self, $locale, $epoch ) = @_;

    $epoch = 0 if !defined $epoch;

    my $metadata = $self->locale_metadata($locale);
    return strftime( $metadata->{date_format}, localtime $epoch );
}

sub format_time {
    my ( $self, $locale, $epoch ) = @_;

    $epoch = 0 if !defined $epoch;

    my $metadata = $self->locale_metadata($locale);
    return strftime( $metadata->{time_format}, localtime $epoch );
}

sub format_datetime {
    my ( $self, $locale, $epoch ) = @_;

    $epoch = 0 if !defined $epoch;

    my $metadata = $self->locale_metadata($locale);
    return strftime( $metadata->{datetime_format}, localtime $epoch );
}

sub format_number {
    my ( $self, $locale, $number ) = @_;

    $number = 0
      if !defined $number || $number !~ /\A -? [0-9]+ (?:[.][0-9]+)? \z/msx;

    my $metadata      = $self->locale_metadata($locale);
    my $decimal_mark  = $metadata->{decimal_mark};
    my $thousand_mark = $metadata->{thousand_mark};
    my $formatted     = sprintf '%.2f', $number;
    my ( $whole, $fraction ) = split /[.]/msx, $formatted;
    my $negative = $whole =~ s/\A-//msx ? q{-} : q{};

    while ( $whole =~ s/\A ([0-9]+) ([0-9]{3}) \z/$1$thousand_mark$2/msx ) {
    }

    return $negative . $whole . $decimal_mark . $fraction;
}

sub catalog_keys {
    my ( $self, $locale ) = @_;

    my $catalog = $self->catalogs->{$locale} || {};
    my @keys    = sort keys %{$catalog};

    return \@keys;
}

sub missing_catalog_keys {
    my ( $self, $locale ) = @_;

    my %fallback = map { $_ => 1 } @{ $self->catalog_keys($FALLBACK_LOCALE) };
    my %catalog  = map { $_ => 1 } @{ $self->catalog_keys($locale) };
    my @missing  = sort grep { !$catalog{$_} } keys %fallback;

    return \@missing;
}

sub has_key {
    my ( $self, $locale, $key ) = @_;

    return exists $self->catalogs->{$locale}
      && exists $self->catalogs->{$locale}{$key}
      ? 1
      : 0;
}

sub _safe_default_locale {
    my ($self) = @_;

    my %supported = map { $_ => 1 } @{ $self->supported_locales };
    my $locale = _supported_locale( _normalize_locale( $self->default_locale ),
        \%supported );

    return defined $locale ? $locale : $FALLBACK_LOCALE;
}

sub _language_ranges {
    my ($accept_language) = @_;

    return if !defined $accept_language || !length $accept_language;

    my $position = 0;
    my @ranges;

    for my $part ( split /,/msx, $accept_language ) {
        $position++;
        my ( $tag, @parameters ) = map { _trim($_) } split /;/msx, $part;
        my $normalized_tag = _normalize_locale($tag);
        next if !length $normalized_tag;

        my $quality = $DEFAULT_QUALITY;
        for my $parameter (@parameters) {
            if ( $parameter =~ /\A q=([01](?:[.][0-9]+)?) \z/imsx ) {
                $quality = $1 + 0;
                last;
            }
        }
        next if $quality <= $ZERO_QUALITY;

        push @ranges,
          {
            tag      => $normalized_tag,
            quality  => $quality,
            position => $position,
          };
    }

    my @sorted_ranges = sort {
             $b->{quality}  <=> $a->{quality}
          || $a->{position} <=> $b->{position}
    } @ranges;

    return @sorted_ranges;
}

sub _supported_locale {
    my ( $tag, $supported ) = @_;

    return      if !defined $tag || !length $tag;
    return $tag if $supported->{$tag};

    my ($base_tag) = split /-/msx, $tag;
    return $base_tag if $supported->{$base_tag};

    return;
}

sub _catalog_message {
    my ( $catalogs, $locale, $key ) = @_;

    return if !defined $locale || !exists $catalogs->{$locale};
    return $catalogs->{$locale}{$key};
}

sub _plural_message {
    my ( $message, $category ) = @_;

    return                       if !defined $message;
    return $message              if ref $message eq q{};
    return                       if ref $message ne 'HASH';
    return $message->{$category} if exists $message->{$category};
    return $message->{other};
}

sub _interpolate {
    my ( $message, $variables ) = @_;

    $message =~ s/\{([A-Za-z0-9_]+)\}/
        exists $variables->{$1} ? $variables->{$1} : q{}
    /egmsx;

    return $message;
}

sub _metadata_for {
    my ($locale) = @_;

    my $metadata_for = _metadata_registry();

    return $metadata_for->{$locale} || $metadata_for->{$FALLBACK_LOCALE};
}

sub _metadata_registry {
    return {
        en => {
            date_format       => '%Y-%m-%d',
            datetime_format   => '%Y-%m-%d %H:%M',
            decimal_mark      => '.',
            direction         => 'ltr',
            font_family_token => 'ui-latin',
            name              => 'English',
            native_name       => 'English',
            number_system     => 'latn',
            script            => 'Latn',
            thousand_mark     => ',',
            time_format       => '%H:%M',
            typography_class  => 'typography-latin',
        },
        it => {
            date_format       => '%d/%m/%Y',
            datetime_format   => '%d/%m/%Y %H:%M',
            decimal_mark      => ',',
            direction         => 'ltr',
            font_family_token => 'ui-latin',
            name              => 'Italian',
            native_name       => 'Italiano',
            number_system     => 'latn',
            script            => 'Latn',
            thousand_mark     => '.',
            time_format       => '%H:%M',
            typography_class  => 'typography-latin',
        },
    };
}

sub _log_missing_key {
    my ( $self, $locale, $key, $reason ) = @_;

    my $logger = $self->missing_key_logger;
    return if !$logger;

    $logger->(
        {
            key    => $key,
            locale => $locale,
            reason => $reason,
        }
    );

    return;
}

sub _normalize_locale {
    my ($tag) = @_;

    return q{} if !defined $tag;

    $tag = lc _trim($tag);
    $tag =~ s/_/-/gmsx;

    return '*' if $tag eq '*';
    return q{} if $tag !~ /\A [a-z]{2,8} (?: - [a-z0-9]{1,8})* \z/msx;

    return $tag;
}

sub _trim {
    my ($value) = @_;

    return q{} if !defined $value;

    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

sub _default_catalogs {
    return {
        en => {
            'app.name'                         => 'GPForum',
            'app.unavailable_title'            => 'GPForum unavailable',
            'auth.create_account'              => 'Create account',
            'auth.display_name'                => 'Display name',
            'auth.email'                       => 'Email',
            'auth.login'                       => 'Login',
            'auth.login_accepted_title'        => 'Login request accepted',
            'auth.login_again'                 => 'Login again',
            'auth.login_next_steps'            => 'Login next steps',
            'auth.login_status'                => 'You are signed in.',
            'auth.login_title'                 => 'Login',
            'auth.logout'                      => 'Logout',
            'auth.logout_accepted_title'       => 'Logout request accepted',
            'auth.logout_aria'                 => 'Logout',
            'auth.logout_next_steps'           => 'Logout next steps',
            'auth.logout_status'               => 'You are signed out.',
            'auth.password'                    => 'Password',
            'auth.register'                    => 'Register',
            'auth.register_title'              => 'Create account',
            'auth.registration_accepted_title' => 'Registration accepted',
            'auth.registration_next_steps'     => 'Registration next steps',
            'auth.registration_ready'    => 'Account {username} is ready.',
            'auth.signed_in_as'          => 'Signed in as {user_id}',
            'auth.username'              => 'Username',
            'auth.username_or_email'     => 'Username or email',
            'admin.admin'                => 'Admin',
            'admin.action'               => 'Action',
            'admin.async_jobs'           => 'Async jobs',
            'admin.attach_permission'    => 'Attach permission',
            'admin.audit'                => 'Audit',
            'admin.audit_log'            => 'Admin audit log',
            'admin.audit_metadata'       => 'Metadata',
            'admin.audit_metadata_label' => 'Audit metadata',
            'admin.audit_summary'        => 'Admin audit summary',
            'admin.benchmark_evidence'   => 'Benchmark evidence',
            'admin.benchmark_status'     => 'Benchmark status',
            'admin.bind_role'            => 'Bind role',
            'admin.configured_command'   => 'Configured command',
            'admin.create_permission'    => 'Create permission',
            'admin.create_role'          => 'Create role',
            'admin.dead_letter_list'     => 'Admin dead-letter list',
            'admin.dead_letters'         => 'Dead letters',
            'admin.description'          => 'Description',
            'admin.display_name'         => 'Display name',
            'admin.email'                => 'Email',
            'admin.endpoint'             => 'Endpoint',
            'admin.error'                => 'Error',
            'admin.fixture_command'      => 'Fixture command',
            'admin.health_runtime'       => 'Health and runtime',
            'admin.jobs_nav'             => 'Admin jobs',
            'admin.last_error'           => 'Last error',
            'admin.last_failed'          => 'Last failed',
            'admin.mode'                 => 'Mode',
            'admin.moderation_summary'   => 'Admin moderation summary',
            'admin.name'                 => 'Name',
            'admin.next_attempt'         => 'Next attempt',
            'admin.no_dead_letters'      => 'No dead letters are available.',
            'admin.no_open_reports'      => 'No open moderation reports.',
            'admin.no_outbox'      => 'No outbox messages match this view.',
            'admin.no_permissions' => 'No permissions have been defined.',
            'admin.no_audit_rows'  => 'No audit rows are available.',
            'admin.no_audit_rows_match' => 'No audit rows match this view.',
            'admin.no_query_budget'  => 'No query budget catalog is available.',
            'admin.no_role_bindings' =>
              'No active role bindings for this user.',
            'admin.no_roles'                 => 'No roles have been defined.',
            'admin.no_users'                 => 'No users match this view.',
            'admin.observed_requests'        => 'Observed requests',
            'admin.outbox'                   => 'Outbox',
            'admin.outbox_list'              => 'Admin outbox list',
            'admin.outbox_pending'           => 'Outbox pending',
            'admin.outbox_rows'              => 'Outbox rows',
            'admin.outbox_status'            => 'Outbox status',
            'admin.permissions'              => 'Permissions',
            'admin.permission_list'          => 'Admin permission list',
            'admin.privacy_review'           => 'Privacy review',
            'admin.queries'                  => '{count} queries',
            'admin.query_budget_drift'       => 'Query budget drift',
            'admin.query_budget_list'        => 'Admin query budget list',
            'admin.query_budget'             => 'Query budget',
            'admin.query_budgets'            => 'Query budgets',
            'admin.queue'                    => 'Queue',
            'admin.readiness'                => 'Readiness',
            'admin.readiness_checks'         => 'Admin readiness checks',
            'admin.resource_id'              => 'Resource id',
            'admin.resource_type'            => 'Resource type',
            'admin.retries'                  => 'Retries',
            'admin.revoked'                  => 'Revoked',
            'admin.revoke_role_binding'      => 'Revoke role binding',
            'admin.role'                     => 'Role',
            'admin.role_id'                  => 'Role id',
            'admin.role_list'                => 'Admin role list',
            'admin.role_summary'             => 'Admin role summary',
            'admin.roles'                    => 'Roles',
            'admin.runtime'                  => 'Runtime',
            'admin.scope'                    => 'Scope',
            'admin.source'                   => 'Source',
            'admin.space_id'                 => 'Space id',
            'admin.status'                   => 'Status',
            'admin.trust_level'              => 'Trust level',
            'admin.user_roles'               => 'User roles',
            'admin.user_role_bindings'       => 'User role bindings',
            'admin.user_list'                => 'Admin user list',
            'admin.user_summary'             => 'Admin user summary',
            'admin.users'                    => 'Users',
            'common.actor'                   => 'Actor',
            'common.any'                     => 'Any',
            'common.correlation'             => 'Correlation',
            'common.created'                 => 'Created',
            'common.details'                 => 'Details',
            'common.filter'                  => 'Filter',
            'common.no'                      => 'No',
            'common.none'                    => 'None',
            'common.reason'                  => 'Reason',
            'common.system'                  => 'system',
            'common.target'                  => 'Target',
            'common.target_id'               => 'Target id',
            'common.target_type'             => 'Target type',
            'common.unassigned'              => 'Unassigned',
            'common.user'                    => 'User',
            'community.added_at'             => 'Added at',
            'community.bookmark_pagination'  => 'Bookmark pagination',
            'community.bookmark_note'        => 'Bookmark note',
            'community.bookmarks'            => 'Bookmarks',
            'community.bookmarks_empty'      => 'No bookmarks saved yet.',
            'community.follow_thread'        => 'Follow thread',
            'community.jump_to_first_unread' => 'Jump to first unread post',
            'community.mute_notifications'   => 'Mute notifications',
            'community.feed'                 => 'Feed',
            'community.feed_empty'           => 'No feed items yet.',
            'community.feed_pagination'      => 'Feed pagination',
            'community.item'                 => 'item',
            'community.older_bookmarks'      => 'Older bookmarks',
            'community.older_feed_items'     => 'Older feed items',
            'community.personal_feed'        => 'Personal feed',
            'community.remove_bookmark'      => 'Remove bookmark',
            'community.saved_at'             => 'Saved at',
            'community.save_bookmark'        => 'Save bookmark',
            'community.unfollow_thread'      => 'Unfollow thread',
            'forum.browse_categories'        => 'Browse categories',
            'forum.back_to_categories'       => 'Back to categories',
            'forum.back_to_category'         => 'Back to category',
            'forum.by_author'                => 'By',
            'forum.categories_empty'  => 'No categories are visible yet.',
            'forum.category_actions'  => 'Category actions',
            'form.error_summary'      => 'Please review the fields below.',
            'form.upload_attachment'  => 'Upload attachment',
            'form.attach_file'        => 'Attach file',
            'forum.create_account'    => 'Create an account',
            'forum.create_thread'     => 'Create thread',
            'forum.error_default'     => 'The request could not be completed.',
            'forum.error_title'       => 'Forum error',
            'forum.forum_actions'     => 'Forum actions',
            'forum.forum_categories'  => 'Forum categories',
            'forum.index_tagline'     => 'Independent discussion index.',
            'forum.index_unavailable' =>
              'The forum index is temporarily unavailable.',
            'forum.last_activity'                => 'Last activity',
            'forum.latest_discussion_pagination' =>
              'Latest discussion pagination',
            'forum.latest_public_discussions' => 'Latest public discussions',
            'forum.login_to_continue'         => 'Login to continue',
            'forum.mark_visible_posts_read'   => 'Mark visible posts as read',
            'forum.new_thread_error_summary'  =>
              'Please fix the highlighted fields before creating the thread.',
            'forum.new_thread_title'      => 'Start a thread',
            'forum.next_threads'          => 'Next threads',
            'forum.next_posts'            => 'Next posts',
            'forum.no_public_discussions' =>
              'No public discussions are visible yet.',
            'forum.no_visible_posts'   => 'No visible posts are available.',
            'forum.no_visible_threads' =>
              'No visible threads are in this category yet.',
            'forum.older_discussions'  => 'Older discussions',
            'forum.permalink'          => 'Permalink',
            'forum.post_attachments'   => 'Post attachments',
            'forum.post_number'        => 'Post {position}',
            'forum.post_pagination'    => 'Post pagination',
            'forum.post_reply'         => 'Post reply',
            'forum.posts'              => 'Posts',
            'forum.reading_caught_up'  => 'You are caught up on this page.',
            'forum.reading_progress'   => 'Reading progress',
            'forum.reply'              => 'Reply',
            'forum.reply_body'         => 'Reply body',
            'forum.realtime_processes' => 'Realtime processes',
            'forum.runtime'            => 'Runtime',
            'forum.started_by'         => 'Started by',
            'forum.thread'             => 'Thread',
            'forum.thread_locked'      => 'This thread is locked.',
            'forum.thread_tools'       => 'Thread tools',
            'forum.thread_body'        => 'Body',
            'forum.thread_pagination'  => 'Thread pagination',
            'forum.thread_title'       => 'Title',
            'forum.validation_errors'  => 'Validation errors',
            'forum.visibility'         => 'Visibility',
            'forum.visibility_members' => 'Members',
            'forum.visibility_private' => 'Private',
            'forum.visibility_public'  => 'Public',
            'forum.web_processes'      => 'Web processes',
            'forum.worker_processes'   => 'Worker processes',
            'layout.flash_messages'    => 'Messages',
            'layout.footer_help'       => 'Help',
            'layout.footer_label'      => 'Product footer',
            'layout.footer_license'    => 'BSD-3 licensed foundation',
            'layout.footer_tagline'   => 'Independent community infrastructure',
            'locale.apply'            => 'Apply',
            'locale.choose'           => 'Language',
            'locale.selector_label'   => 'Language selector',
            'ui.actions'              => 'Page actions',
            'ui.admin_table'          => 'Admin table',
            'ui.confirmation'         => 'Confirmation',
            'ui.dialog_close'         => 'Close dialog',
            'ui.empty_state'          => 'Nothing to show yet',
            'ui.loading'              => 'Loading',
            'ui.moderation_indicator' => 'Moderation state:',
            'ui.pagination'           => 'Pagination',
            'ui.status_banner'        => 'Status',
            'moderation.action.post_hidden'     => 'Post hidden',
            'moderation.action.post_restored'   => 'Post restored',
            'moderation.action.thread_locked'   => 'Thread locked',
            'moderation.action.thread_unlocked' => 'Thread unlocked',
            'moderation.action_history'         => 'Moderation action history',
            'moderation.actions'                => 'Moderation actions',
            'moderation.active_suspension_list' => 'Active suspension list',
            'moderation.assign_to_me'           => 'Assign to me',
            'moderation.hide_post'              => 'Hide post',
            'moderation.lock_thread'            => 'Lock thread',
            'moderation.next_actions'           => 'Next actions',
            'moderation.next_suspensions'       => 'Next suspensions',
            'moderation.no_actions_match'       =>
              'No moderation actions match this view.',
            'moderation.no_reports_match'     => 'No reports match this queue.',
            'moderation.no_suspensions_match' =>
              'No suspensions match this view.',
            'moderation.queue'                     => 'Moderation queue',
            'moderation.reason.abuse'              => 'Abuse',
            'moderation.reason.other'              => 'Other',
            'moderation.reason.privacy'            => 'Privacy',
            'moderation.reason.spam'               => 'Spam',
            'moderation.release_claim'             => 'Release claim',
            'moderation.report_post'               => 'Report post',
            'moderation.report_profile'            => 'Report profile',
            'moderation.report_queue'              => 'Moderation report queue',
            'moderation.report_thread'             => 'Report thread',
            'moderation.reports'                   => 'Moderation reports',
            'moderation.resolution'                => 'Resolution',
            'moderation.resolution.content_hidden' => 'Content hidden',
            'moderation.resolution.escalated'      => 'Escalated',
            'moderation.resolution.no_action'      => 'No action',
            'moderation.resolution.user_warned'    => 'User warned',
            'moderation.resolve_report'            => 'Resolve report',
            'moderation.restore_post'              => 'Restore post',
            'moderation.reverse_action'            => 'Reverse action',
            'moderation.reversed'                  => 'Reversed',
            'moderation.revoke_suspension'         => 'Revoke suspension',
            'moderation.suspend_user'              => 'Suspend user',
            'moderation.submit_report'             => 'Submit report',
            'moderation.suspensions'               => 'Suspensions',
            'moderation.unlock_thread'             => 'Unlock thread',
            'moderation.user_id'                   => 'User id',
            'moderation.valid_from'                => 'Valid from',
            'moderation.valid_to'                  => 'Valid until',
            'mentions.by'                          => 'Mention by',
            'mentions.email_body'                  =>
              'Open GPForum to review the mention from {actor}.',
            'mentions.email_subject'   => '{actor} mentioned you on GPForum',
            'mentions.empty'           => 'No mentions yet.',
            'mentions.list_label'      => 'Mention list',
            'mentions.mentioned_at'    => 'Mentioned at',
            'mentions.open_discussion' => 'Open discussion',
            'mentions.older'           => 'Older mentions',
            'mentions.pagination'      => 'Mention pagination',
            'mentions.source'          => 'Source',
            'mentions.summary'         =>
              'This mention is linked to {source_type} {source_id}.',
            'mentions.title'       => 'Mention',
            'nav.admin'            => 'Admin',
            'nav.bookmarks'        => 'Bookmarks',
            'nav.breadcrumbs'      => 'Breadcrumbs',
            'nav.categories'       => 'Categories',
            'nav.feed'             => 'Feed',
            'nav.home'             => 'Home',
            'nav.identity'         => 'Identity',
            'nav.mentions'         => 'Mentions',
            'nav.moderation'       => 'Moderation',
            'nav.notifications'    => 'Notifications',
            'nav.primary'          => 'Primary',
            'nav.profile'          => 'Profile',
            'nav.privacy'          => 'Privacy',
            'nav.search'           => 'Search',
            'nav.settings'         => 'Settings',
            'nav.skip_to_content'  => 'Skip to content',
            'nav.start_thread'     => 'Start a thread',
            'settings.appearance'  => 'Language and theme',
            'settings.description' =>
              'Choose how GPForum renders the interface for your account.',
            'settings.login_required' => 'Sign in to manage your preferences.',
            'settings.notification_channels'     => 'Notification channels',
            'settings.notifications'             => 'Notifications',
            'settings.notifications_description' =>
              'Control which product channels are allowed to notify you.',
            'settings.save'             => 'Save preferences',
            'settings.saved'            => 'Preferences saved.',
            'settings.title'            => 'Settings',
            'theme.apply'               => 'Apply',
            'theme.choose'              => 'Theme',
            'theme.dark'                => 'Dark',
            'theme.default'             => 'Default',
            'theme.high_contrast'       => 'High contrast',
            'theme.selector_label'      => 'Theme selector',
            'notifications.body.follow' =>
              'A followed thread has new activity.',
            'notifications.body.mention' =>
              'You were mentioned in a discussion.',
            'notifications.body.notification' => 'You have a new notification.',
            'notifications.body.reply' => 'A followed thread has a new reply.',
            'notifications.channel.digest'             => 'Digest',
            'notifications.channel.email'              => 'Email',
            'notifications.channel.in_app'             => 'In-app',
            'notifications.digest_frequency'           => 'Digest frequency',
            'notifications.digest_frequency.daily'     => 'Daily',
            'notifications.digest_frequency.immediate' => 'Immediate',
            'notifications.digest_frequency.never'     => 'Never',
            'notifications.digest_frequency.weekly'    => 'Weekly',
            'notifications.email_body.follow'          =>
              'Open GPForum to review new activity in a thread you follow.',
            'notifications.email_body.mention' =>
              'Open GPForum to review the discussion where you were mentioned.',
            'notifications.email_body.notification' =>
              'Open GPForum to review your notification.',
            'notifications.email_body.reply' =>
              'Open GPForum to read the new reply in a thread you follow.',
            'notifications.email_subject.follow' =>
              'New activity in a followed thread',
            'notifications.email_subject.mention' =>
              'You were mentioned on GPForum',
            'notifications.email_subject.notification' =>
              'New notification on GPForum',
            'notifications.email_subject.reply' =>
              'New reply in a followed thread',
            'notifications.empty'           => 'No notifications yet.',
            'notifications.inbox_label'     => 'Notification inbox',
            'notifications.mark_read'       => 'Mark notification as read',
            'notifications.older'           => 'Older notifications',
            'notifications.open_discussion' => 'Open discussion',
            'notifications.pagination'      => 'Notification pagination',
            'notifications.preference.digest.description' =>
              'Receive periodic summaries when digest delivery is enabled.',
            'notifications.preference.email.description' =>
              'Allow email delivery for account and community notifications.',
            'notifications.preference.in_app.description' =>
              'Show notifications inside your GPForum inbox.',
            'notifications.read'         => 'Read',
            'notifications.received_at'  => 'Received at',
            'notifications.title.follow' => 'New activity in a followed thread',
            'notifications.title.mention'      => 'You were mentioned',
            'notifications.title.notification' => 'Notification',
            'notifications.title.reply'  => 'New reply in a followed thread',
            'notifications.type.follow'  => 'Follow',
            'notifications.type.mention' => 'Mention',
            'notifications.type.notification' => 'Notification',
            'notifications.type.reply'        => 'Reply',
            'notifications.unread_count'      => {
                one   => '{count} unread',
                other => '{count} unread',
            },
            'profile.contributor_summary' => 'Contributor summary',
            'profile.discussion_reply'    => 'Discussion reply',
            'profile.joined'              => 'Joined',
            'profile.new_contributor'     => 'New contributor',
            'profile.not_found_message'   =>
              'The requested public profile is not available.',
            'profile.not_found_title'          => 'Profile not found',
            'profile.no_public_discussions'    => 'No public discussions yet.',
            'profile.no_public_replies'        => 'No public replies yet.',
            'profile.older_public_discussions' => 'Older public discussions',
            'profile.profile_activity_pagination' =>
              'Profile activity pagination',
            'profile.public_contributions' => 'Public contributions',
            'profile.public_discussions'   => 'Public discussions',
            'profile.public_discussions_by_contributor' =>
              'Public discussions by this contributor',
            'profile.public_replies'        => 'Public replies',
            'profile.public_threads'        => 'Public threads',
            'profile.recent_public_replies' => 'Recent public replies',
            'profile.recent_public_replies_by_contributor' =>
              'Recent public replies by this contributor',
            'profile.replied'                   => 'Replied',
            'profile.reputation_score'          => 'Reputation score',
            'profile.trust_badge'               => 'Trust badge',
            'permission.admin_console_view'     => 'View admin console',
            'privacy.account_deletion'          => 'Account deletion',
            'privacy.account_deletion_requests' => 'Account deletion requests',
            'privacy.active_holds'              => 'Active holds',
            'privacy.active_legal_holds'        => 'Active legal holds',
            'privacy.active_retention_holds'    => 'Active retention holds',
            'privacy.apply_hold'                => 'Apply hold',
            'privacy.approval_reason'           => 'Approval reason',
            'privacy.approve_erasure'           => 'Approve erasure',
            'privacy.data_export'               => 'Data export',
            'privacy.data_export_requests'      => 'Data export requests',
            'privacy.deletion_requests'         => 'Deletion requests',
            'privacy.erasure_jobs'              => 'Erasure jobs',
            'privacy.export_requests'           => 'Export requests',
            'privacy.hold_reason'               => 'Hold reason',
            'privacy.no_deletion_requests'      => 'No deletion requests yet.',
            'privacy.no_deletion_review'        =>
              'No deletion requests are waiting for review.',
            'privacy.no_erasure_pending' => 'No erasure jobs are pending.',
            'privacy.no_export_pending'  => 'No export requests are pending.',
            'privacy.no_export_requests' => 'No export requests yet.',
            'privacy.pending_deletion_requests' => 'Pending deletion requests',
            'privacy.pending_erasure_jobs'      => 'Pending erasure jobs',
            'privacy.pending_export_requests'   => 'Pending export requests',
            'privacy.request_deletion'          => 'Request deletion',
            'privacy.request_export'            => 'Request export',
            'privacy.retention_holds'           => 'Retention holds',
            'privacy.review'                    => 'Privacy review',
            'privacy.run_erasure'               => 'Run erasure',
            'state.active'                      => 'Active',
            'state.all'                         => 'All',
            'state.cancelled'                   => 'Cancelled',
            'state.completed'                   => 'Completed',
            'state.done'                        => 'Done',
            'state.failed'                      => 'Failed',
            'state.indefinite'                  => 'Indefinite',
            'state.manual'                      => 'Manual',
            'state.ok'                          => 'OK',
            'state.open'                        => 'Open',
            'state.pending'                     => 'Pending',
            'state.rejected'                    => 'Rejected',
            'state.resolved'                    => 'Resolved',
            'state.suspended'                   => 'Suspended',
            'state.triaged'                     => 'Triaged',
            'state.unknown'                     => 'Unknown',
            'target.post'                       => 'Post',
            'target.thread'                     => 'Thread',
            'target.user'                       => 'User',
            'data.attachments'                  => 'attachments',
            'data.notifications'                => 'notifications',
            'data.posts'                        => 'Posts',
            'data.subscriptions'                => 'subscriptions',
            'search.author'                     => 'Author',
            'search.by_author'                  => 'By',
            'search.category'                   => 'Category',
            'search.degraded'       => 'Search is temporarily degraded.',
            'search.empty_guidance' =>
'Search public discussions, replies, categories, authors, or date ranges.',
            'search.empty_title' => 'Search the forum',
            'search.filters'     => 'Filters',
            'search.from'        => 'From',
            'search.help'        =>
'Results respect visibility, moderation, and your current permissions.',
            'search.more_results' => 'Show more results',
            'search.no_results'   => 'No visible results matched your search.',
            'search.no_results_guidance' =>
              'Try a broader query, remove a filter, or check the spelling.',
            'search.pagination'      => 'Search pagination',
            'search.permission_note' =>
              'Snippets only include content you are allowed to read.',
            'search.query'           => 'Search query',
            'search.results'         => 'Search results',
            'search.results_summary' => '{count} results',
            'search.submit'          => 'Search',
            'search.title'           => 'Search',
            'search.to'              => 'To',
        },
        it => {
            'app.name'                         => 'GPForum',
            'app.unavailable_title'            => 'GPForum non disponibile',
            'auth.create_account'              => 'Crea account',
            'auth.display_name'                => 'Nome pubblico',
            'auth.email'                       => 'Email',
            'auth.login'                       => 'Accedi',
            'auth.login_accepted_title'        => 'Richiesta accesso accettata',
            'auth.login_again'                 => 'Accedi di nuovo',
            'auth.login_next_steps'            => 'Passi successivi accesso',
            'auth.login_status'                => 'Hai effettuato l’accesso.',
            'auth.login_title'                 => 'Accesso',
            'auth.logout'                      => 'Esci',
            'auth.logout_accepted_title'       => 'Richiesta uscita accettata',
            'auth.logout_aria'                 => 'Esci',
            'auth.logout_next_steps'           => 'Passi successivi uscita',
            'auth.logout_status'               => 'Sei uscito.',
            'auth.password'                    => 'Password',
            'auth.register'                    => 'Registrati',
            'auth.register_title'              => 'Crea account',
            'auth.registration_accepted_title' => 'Registrazione accettata',
            'auth.registration_next_steps' => 'Passi successivi registrazione',
            'auth.registration_ready'      => 'Account {username} pronto.',
            'auth.signed_in_as'            => 'Accesso come {user_id}',
            'auth.username'                => 'Nome utente',
            'auth.username_or_email'       => 'Nome utente o email',
            'admin.admin'                  => 'Admin',
            'admin.action'                 => 'Azione',
            'admin.async_jobs'             => 'Job asincroni',
            'admin.attach_permission'      => 'Collega permesso',
            'admin.audit'                  => 'Audit',
            'admin.audit_log'              => 'Log audit admin',
            'admin.audit_metadata'         => 'Metadata',
            'admin.audit_metadata_label'   => 'Metadata audit',
            'admin.audit_summary'          => 'Riepilogo audit admin',
            'admin.benchmark_evidence'     => 'Evidenza benchmark',
            'admin.benchmark_status'       => 'Stato benchmark',
            'admin.bind_role'              => 'Associa ruolo',
            'admin.configured_command'     => 'Comando configurato',
            'admin.create_permission'      => 'Crea permesso',
            'admin.create_role'            => 'Crea ruolo',
            'admin.dead_letter_list'       => 'Elenco dead-letter admin',
            'admin.dead_letters'           => 'Dead letter',
            'admin.description'            => 'Descrizione',
            'admin.display_name'           => 'Nome pubblico',
            'admin.email'                  => 'Email',
            'admin.endpoint'               => 'Endpoint',
            'admin.error'                  => 'Errore',
            'admin.fixture_command'        => 'Comando fixture',
            'admin.health_runtime'         => 'Salute e runtime',
            'admin.jobs_nav'               => 'Job admin',
            'admin.last_error'             => 'Ultimo errore',
            'admin.last_failed'            => 'Ultimo fallimento',
            'admin.mode'                   => 'Modo',
            'admin.moderation_summary'     => 'Riepilogo moderazione admin',
            'admin.name'                   => 'Nome',
            'admin.next_attempt'           => 'Prossimo tentativo',
            'admin.no_dead_letters' => 'Nessuna dead letter disponibile.',
            'admin.no_open_reports' => 'Nessuna segnalazione aperta.',
            'admin.no_outbox'       =>
              'Nessun messaggio outbox corrisponde a questa vista.',
            'admin.no_permissions'      => 'Nessun permesso definito.',
            'admin.no_audit_rows'       => 'Nessuna riga audit disponibile.',
            'admin.no_audit_rows_match' =>
              'Nessuna riga audit corrisponde alla vista.',
            'admin.no_query_budget' =>
              'Nessun catalogo query budget disponibile.',
            'admin.no_role_bindings' =>
              'Nessuna associazione ruolo attiva per questo utente.',
            'admin.no_roles' => 'Nessun ruolo definito.',
            'admin.no_users' => 'Nessun utente corrisponde alla vista.',
            'admin.observed_requests'        => 'Richieste osservate',
            'admin.outbox'                   => 'Outbox',
            'admin.outbox_list'              => 'Elenco outbox admin',
            'admin.outbox_pending'           => 'Outbox in attesa',
            'admin.outbox_rows'              => 'Righe outbox',
            'admin.outbox_status'            => 'Stato outbox',
            'admin.permissions'              => 'Permessi',
            'admin.permission_list'          => 'Elenco permessi admin',
            'admin.privacy_review'           => 'Revisione privacy',
            'admin.queries'                  => '{count} query',
            'admin.query_budget_drift'       => 'Drift query budget',
            'admin.query_budget_list'        => 'Elenco query budget admin',
            'admin.query_budget'             => 'Query budget',
            'admin.query_budgets'            => 'Query budget',
            'admin.queue'                    => 'Coda',
            'admin.readiness'                => 'Readiness',
            'admin.readiness_checks'         => 'Controlli readiness admin',
            'admin.resource_id'              => 'ID risorsa',
            'admin.resource_type'            => 'Tipo risorsa',
            'admin.retries'                  => 'Retry',
            'admin.revoked'                  => 'Revocato',
            'admin.revoke_role_binding'      => 'Revoca associazione ruolo',
            'admin.role'                     => 'Ruolo',
            'admin.role_id'                  => 'ID ruolo',
            'admin.role_list'                => 'Elenco ruoli admin',
            'admin.role_summary'             => 'Riepilogo ruoli admin',
            'admin.roles'                    => 'Ruoli',
            'admin.runtime'                  => 'Runtime',
            'admin.scope'                    => 'Ambito',
            'admin.source'                   => 'Sorgente',
            'admin.space_id'                 => 'ID spazio',
            'admin.status'                   => 'Stato',
            'admin.trust_level'              => 'Livello trust',
            'admin.user_roles'               => 'Ruoli utente',
            'admin.user_role_bindings'       => 'Associazioni ruoli utente',
            'admin.user_list'                => 'Elenco utenti admin',
            'admin.user_summary'             => 'Riepilogo utenti admin',
            'admin.users'                    => 'Utenti',
            'common.actor'                   => 'Attore',
            'common.any'                     => 'Qualsiasi',
            'common.correlation'             => 'Correlazione',
            'common.created'                 => 'Creato',
            'common.details'                 => 'Dettagli',
            'common.filter'                  => 'Filtra',
            'common.no'                      => 'No',
            'common.none'                    => 'Nessuno',
            'common.reason'                  => 'Motivo',
            'common.system'                  => 'sistema',
            'common.target'                  => 'Target',
            'common.target_id'               => 'ID target',
            'common.target_type'             => 'Tipo target',
            'common.unassigned'              => 'Non assegnato',
            'common.user'                    => 'Utente',
            'community.added_at'             => 'Aggiunto alle',
            'community.bookmark_pagination'  => 'Paginazione segnalibri',
            'community.bookmark_note'        => 'Nota segnalibro',
            'community.bookmarks'            => 'Segnalibri',
            'community.bookmarks_empty'      => 'Nessun segnalibro salvato.',
            'community.follow_thread'        => 'Segui discussione',
            'community.jump_to_first_unread' => 'Vai al primo post non letto',
            'community.mute_notifications'   => 'Silenzia notifiche',
            'community.feed'                 => 'Feed',
            'community.feed_empty'           => 'Nessun elemento nel feed.',
            'community.feed_pagination'      => 'Paginazione feed',
            'community.item'                 => 'elemento',
            'community.older_bookmarks'      => 'Segnalibri precedenti',
            'community.older_feed_items'     => 'Elementi feed precedenti',
            'community.personal_feed'        => 'Feed personale',
            'community.remove_bookmark'      => 'Rimuovi segnalibro',
            'community.saved_at'             => 'Salvato alle',
            'community.save_bookmark'        => 'Salva segnalibro',
            'community.unfollow_thread'      => 'Smetti di seguire',
            'forum.browse_categories'        => 'Sfoglia categorie',
            'forum.back_to_categories'       => 'Torna alle categorie',
            'forum.back_to_category'         => 'Torna alla categoria',
            'forum.by_author'                => 'Di',
            'forum.categories_empty'         => 'Nessuna categoria visibile.',
            'forum.category_actions'         => 'Azioni categoria',
            'form.error_summary'             => 'Controlla i campi qui sotto.',
            'form.upload_attachment'         => 'Carica allegato',
            'form.attach_file'               => 'Allega file',
            'forum.create_account'           => 'Crea un account',
            'forum.create_thread'            => 'Crea discussione',
            'forum.error_default' => 'La richiesta non può essere completata.',
            'forum.error_title'   => 'Errore forum',
            'forum.forum_actions' => 'Azioni forum',
            'forum.forum_categories'  => 'Categorie forum',
            'forum.index_tagline'     => 'Indice discussioni indipendente.',
            'forum.index_unavailable' =>
              'L’indice forum è temporaneamente non disponibile.',
            'forum.last_activity'                => 'Ultima attività',
            'forum.latest_discussion_pagination' =>
              'Paginazione discussioni recenti',
            'forum.latest_public_discussions' =>
              'Discussioni pubbliche recenti',
            'forum.login_to_continue'       => 'Accedi per continuare',
            'forum.mark_visible_posts_read' =>
              'Segna i post visibili come letti',
            'forum.new_thread_error_summary' =>
              'Correggi i campi evidenziati prima di creare la discussione.',
            'forum.new_thread_title'      => 'Avvia una discussione',
            'forum.next_posts'            => 'Post successivi',
            'forum.next_threads'          => 'Discussioni successive',
            'forum.no_public_discussions' =>
              'Nessuna discussione pubblica visibile.',
            'forum.no_visible_posts'   => 'Nessun post visibile è disponibile.',
            'forum.no_visible_threads' =>
              'Nessuna discussione visibile in questa categoria.',
            'forum.older_discussions'  => 'Discussioni precedenti',
            'forum.permalink'          => 'Permalink',
            'forum.post_attachments'   => 'Allegati post',
            'forum.post_number'        => 'Post {position}',
            'forum.post_pagination'    => 'Paginazione post',
            'forum.post_reply'         => 'Pubblica risposta',
            'forum.posts'              => 'Post',
            'forum.reading_caught_up'  => 'Sei allineato con questa pagina.',
            'forum.reading_progress'   => 'Avanzamento lettura',
            'forum.reply'              => 'Risposta',
            'forum.reply_body'         => 'Corpo risposta',
            'forum.realtime_processes' => 'Processi realtime',
            'forum.runtime'            => 'Runtime',
            'forum.started_by'         => 'Avviata da',
            'forum.thread'             => 'Discussione',
            'forum.thread_locked'      => 'Questa discussione è bloccata.',
            'forum.thread_tools'       => 'Strumenti discussione',
            'forum.thread_body'        => 'Corpo',
            'forum.thread_pagination'  => 'Paginazione discussioni',
            'forum.thread_title'       => 'Titolo',
            'forum.validation_errors'  => 'Errori di validazione',
            'forum.visibility'         => 'Visibilità',
            'forum.visibility_members' => 'Membri',
            'forum.visibility_private' => 'Privata',
            'forum.visibility_public'  => 'Pubblica',
            'forum.web_processes'      => 'Processi web',
            'forum.worker_processes'   => 'Processi worker',
            'layout.flash_messages'    => 'Messaggi',
            'layout.footer_help'       => 'Aiuto',
            'layout.footer_label'      => 'Footer prodotto',
            'layout.footer_license'    => 'Fondazione con licenza BSD-3',
            'layout.footer_tagline'    =>
              'Infrastruttura indipendente per comunità',
            'locale.apply'                      => 'Applica',
            'locale.choose'                     => 'Lingua',
            'locale.selector_label'             => 'Selettore lingua',
            'ui.actions'                        => 'Azioni pagina',
            'ui.admin_table'                    => 'Tabella admin',
            'ui.confirmation'                   => 'Conferma',
            'ui.dialog_close'                   => 'Chiudi dialog',
            'ui.empty_state'                    => 'Niente da mostrare',
            'ui.loading'                        => 'Caricamento',
            'ui.moderation_indicator'           => 'Stato moderazione:',
            'ui.pagination'                     => 'Paginazione',
            'ui.status_banner'                  => 'Stato',
            'moderation.action.post_hidden'     => 'Post nascosto',
            'moderation.action.post_restored'   => 'Post ripristinato',
            'moderation.action.thread_locked'   => 'Thread bloccato',
            'moderation.action.thread_unlocked' => 'Thread sbloccato',
            'moderation.action_history'         => 'Storico azioni moderazione',
            'moderation.actions'                => 'Azioni moderazione',
            'moderation.active_suspension_list' => 'Elenco sospensioni attive',
            'moderation.assign_to_me'           => 'Assegna a me',
            'moderation.hide_post'              => 'Nascondi post',
            'moderation.lock_thread'            => 'Blocca thread',
            'moderation.next_actions'           => 'Azioni successive',
            'moderation.next_suspensions'       => 'Sospensioni successive',
            'moderation.no_actions_match'       =>
              'Nessuna azione moderativa corrisponde alla vista.',
            'moderation.no_reports_match' =>
              'Nessuna segnalazione corrisponde alla coda.',
            'moderation.no_suspensions_match' =>
              'Nessuna sospensione corrisponde alla vista.',
            'moderation.queue'          => 'Coda moderazione',
            'moderation.reason.abuse'   => 'Abuso',
            'moderation.reason.other'   => 'Altro',
            'moderation.reason.privacy' => 'Privacy',
            'moderation.reason.spam'    => 'Spam',
            'moderation.release_claim'  => 'Rilascia claim',
            'moderation.report_post'    => 'Segnala post',
            'moderation.report_profile' => 'Segnala profilo',
            'moderation.report_queue'   => 'Coda segnalazioni moderazione',
            'moderation.report_thread'  => 'Segnala discussione',
            'moderation.reports'        => 'Segnalazioni moderazione',
            'moderation.resolution'     => 'Risoluzione',
            'moderation.resolution.content_hidden' => 'Contenuto nascosto',
            'moderation.resolution.escalated'      => 'Escalato',
            'moderation.resolution.no_action'      => 'Nessuna azione',
            'moderation.resolution.user_warned'    => 'Utente avvisato',
            'moderation.resolve_report'            => 'Risolvi segnalazione',
            'moderation.restore_post'              => 'Ripristina post',
            'moderation.reverse_action'            => 'Annulla azione',
            'moderation.reversed'                  => 'Annullata',
            'moderation.revoke_suspension'         => 'Revoca sospensione',
            'moderation.suspend_user'              => 'Sospendi utente',
            'moderation.submit_report'             => 'Invia segnalazione',
            'moderation.suspensions'               => 'Sospensioni',
            'moderation.unlock_thread'             => 'Sblocca thread',
            'moderation.user_id'                   => 'ID utente',
            'moderation.valid_from'                => 'Valida da',
            'moderation.valid_to'                  => 'Valida fino a',
            'mentions.by'                          => 'Menzione da',
            'mentions.email_body'                  =>
              'Apri GPForum per controllare la menzione da {actor}.',
            'mentions.email_subject'   => '{actor} ti ha menzionato su GPForum',
            'mentions.empty'           => 'Nessuna menzione.',
            'mentions.list_label'      => 'Elenco menzioni',
            'mentions.mentioned_at'    => 'Menzionata alle',
            'mentions.open_discussion' => 'Apri discussione',
            'mentions.older'           => 'Menzioni precedenti',
            'mentions.pagination'      => 'Paginazione menzioni',
            'mentions.source'          => 'Sorgente',
            'mentions.summary'         =>
              'Questa menzione è collegata a {source_type} {source_id}.',
            'mentions.title'       => 'Menzione',
            'nav.admin'            => 'Admin',
            'nav.bookmarks'        => 'Segnalibri',
            'nav.breadcrumbs'      => 'Percorso',
            'nav.categories'       => 'Categorie',
            'nav.feed'             => 'Feed',
            'nav.home'             => 'Home',
            'nav.identity'         => 'Identità',
            'nav.mentions'         => 'Menzioni',
            'nav.moderation'       => 'Moderazione',
            'nav.notifications'    => 'Notifiche',
            'nav.primary'          => 'Principale',
            'nav.profile'          => 'Profilo',
            'nav.privacy'          => 'Privacy',
            'nav.search'           => 'Cerca',
            'nav.settings'         => 'Impostazioni',
            'nav.skip_to_content'  => 'Vai al contenuto',
            'nav.start_thread'     => 'Avvia una discussione',
            'settings.appearance'  => 'Lingua e tema',
            'settings.description' =>
              'Scegli come GPForum mostra l’interfaccia del tuo account.',
            'settings.login_required' =>
              'Accedi per gestire le tue preferenze.',
            'settings.notification_channels'     => 'Canali di notifica',
            'settings.notifications'             => 'Notifiche',
            'settings.notifications_description' =>
              'Controlla quali canali prodotto possono notificarti.',
            'settings.save'             => 'Salva preferenze',
            'settings.saved'            => 'Preferenze salvate.',
            'settings.title'            => 'Impostazioni',
            'theme.apply'               => 'Applica',
            'theme.choose'              => 'Tema',
            'theme.dark'                => 'Scuro',
            'theme.default'             => 'Predefinito',
            'theme.high_contrast'       => 'Alto contrasto',
            'theme.selector_label'      => 'Selettore tema',
            'notifications.body.follow' =>
              'Una discussione seguita ha nuova attività.',
            'notifications.body.mention' =>
              'Sei stato menzionato in una discussione.',
            'notifications.body.notification' => 'Hai una nuova notifica.',
            'notifications.body.reply'        =>
              'Una discussione seguita ha una nuova risposta.',
            'notifications.channel.digest'             => 'Riepilogo',
            'notifications.channel.email'              => 'Email',
            'notifications.channel.in_app'             => 'Nel prodotto',
            'notifications.digest_frequency'           => 'Frequenza riepilogo',
            'notifications.digest_frequency.daily'     => 'Giornaliera',
            'notifications.digest_frequency.immediate' => 'Immediata',
            'notifications.digest_frequency.never'     => 'Mai',
            'notifications.digest_frequency.weekly'    => 'Settimanale',
            'notifications.email_body.follow'          =>
'Apri GPForum per controllare la nuova attività in una discussione seguita.',
            'notifications.email_body.mention' =>
'Apri GPForum per controllare la discussione in cui sei stato menzionato.',
            'notifications.email_body.notification' =>
              'Apri GPForum per controllare la notifica.',
            'notifications.email_body.reply' =>
'Apri GPForum per leggere la nuova risposta in una discussione seguita.',
            'notifications.email_subject.follow' =>
              'Nuova attività in una discussione seguita',
            'notifications.email_subject.mention' =>
              'Sei stato menzionato su GPForum',
            'notifications.email_subject.notification' =>
              'Nuova notifica su GPForum',
            'notifications.email_subject.reply' =>
              'Nuova risposta in una discussione seguita',
            'notifications.empty'           => 'Nessuna notifica.',
            'notifications.inbox_label'     => 'Inbox notifiche',
            'notifications.mark_read'       => 'Segna notifica come letta',
            'notifications.older'           => 'Notifiche precedenti',
            'notifications.open_discussion' => 'Apri discussione',
            'notifications.pagination'      => 'Paginazione notifiche',
            'notifications.preference.digest.description' =>
              'Ricevi riepiloghi periodici quando il digest è attivo.',
            'notifications.preference.email.description' =>
              'Consenti l’invio email per notifiche account e community.',
            'notifications.preference.in_app.description' =>
              'Mostra notifiche nella inbox di GPForum.',
            'notifications.read'         => 'Letta',
            'notifications.received_at'  => 'Ricevuta alle',
            'notifications.title.follow' =>
              'Nuova attività in una discussione seguita',
            'notifications.title.mention'      => 'Sei stato menzionato',
            'notifications.title.notification' => 'Notifica',
            'notifications.title.reply'        =>
              'Nuova risposta in una discussione seguita',
            'notifications.type.follow'       => 'Follow',
            'notifications.type.mention'      => 'Menzione',
            'notifications.type.notification' => 'Notifica',
            'notifications.type.reply'        => 'Risposta',
            'notifications.unread_count'      => {
                one   => '{count} non letta',
                other => '{count} non lette',
            },
            'profile.contributor_summary' => 'Riepilogo contributor',
            'profile.discussion_reply'    => 'Risposta alla discussione',
            'profile.joined'              => 'Iscrizione',
            'profile.new_contributor'     => 'Nuovo contributor',
            'profile.not_found_message'   =>
              'Il profilo pubblico richiesto non è disponibile.',
            'profile.not_found_title'       => 'Profilo non trovato',
            'profile.no_public_discussions' => 'Nessuna discussione pubblica.',
            'profile.no_public_replies'     => 'Nessuna risposta pubblica.',
            'profile.older_public_discussions' =>
              'Discussioni pubbliche precedenti',
            'profile.profile_activity_pagination' =>
              'Paginazione attività profilo',
            'profile.public_contributions' => 'Contributi pubblici',
            'profile.public_discussions'   => 'Discussioni pubbliche',
            'profile.public_discussions_by_contributor' =>
              'Discussioni pubbliche di questo contributor',
            'profile.public_replies'        => 'Risposte pubbliche',
            'profile.public_threads'        => 'Thread pubblici',
            'profile.recent_public_replies' => 'Risposte pubbliche recenti',
            'profile.recent_public_replies_by_contributor' =>
              'Risposte pubbliche recenti di questo contributor',
            'profile.replied'                   => 'Risposto',
            'profile.reputation_score'          => 'Punteggio reputazione',
            'profile.trust_badge'               => 'Badge trust',
            'permission.admin_console_view'     => 'Vedi console admin',
            'privacy.account_deletion'          => 'Cancellazione account',
            'privacy.account_deletion_requests' =>
              'Richieste cancellazione account',
            'privacy.active_holds'           => 'Hold attivi',
            'privacy.active_legal_holds'     => 'Legal hold attivi',
            'privacy.active_retention_holds' => 'Retention hold attivi',
            'privacy.apply_hold'             => 'Applica hold',
            'privacy.approval_reason'        => 'Motivo approvazione',
            'privacy.approve_erasure'        => 'Approva erasure',
            'privacy.data_export'            => 'Export dati',
            'privacy.data_export_requests'   => 'Richieste export dati',
            'privacy.deletion_requests'      => 'Richieste cancellazione',
            'privacy.erasure_jobs'           => 'Job erasure',
            'privacy.export_requests'        => 'Richieste export',
            'privacy.hold_reason'            => 'Motivo hold',
            'privacy.no_deletion_requests'   =>
              'Nessuna richiesta cancellazione.',
            'privacy.no_deletion_review' =>
              'Nessuna richiesta cancellazione in attesa di revisione.',
            'privacy.no_erasure_pending' => 'Nessun job erasure in attesa.',
            'privacy.no_export_pending'  =>
              'Nessuna richiesta export in attesa.',
            'privacy.no_export_requests'        => 'Nessuna richiesta export.',
            'privacy.pending_deletion_requests' =>
              'Richieste cancellazione in attesa',
            'privacy.pending_erasure_jobs'    => 'Job erasure in attesa',
            'privacy.pending_export_requests' => 'Richieste export in attesa',
            'privacy.request_deletion'        => 'Richiedi cancellazione',
            'privacy.request_export'          => 'Richiedi export',
            'privacy.retention_holds'         => 'Retention hold',
            'privacy.review'                  => 'Revisione privacy',
            'privacy.run_erasure'             => 'Esegui erasure',
            'state.active'                    => 'Attivo',
            'state.all'                       => 'Tutti',
            'state.cancelled'                 => 'Annullato',
            'state.completed'                 => 'Completato',
            'state.done'                      => 'Completato',
            'state.failed'                    => 'Fallito',
            'state.indefinite'                => 'Indefinita',
            'state.manual'                    => 'Manuale',
            'state.ok'                        => 'OK',
            'state.open'                      => 'Aperto',
            'state.pending'                   => 'In attesa',
            'state.rejected'                  => 'Respinto',
            'state.resolved'                  => 'Risolto',
            'state.suspended'                 => 'Sospeso',
            'state.triaged'                   => 'Triaged',
            'state.unknown'                   => 'Sconosciuto',
            'target.post'                     => 'Post',
            'target.thread'                   => 'Thread',
            'target.user'                     => 'Utente',
            'data.attachments'                => 'allegati',
            'data.notifications'              => 'notifiche',
            'data.posts'                      => 'Post',
            'data.subscriptions'              => 'sottoscrizioni',
            'search.author'                   => 'Autore',
            'search.by_author'                => 'Di',
            'search.category'                 => 'Categoria',
            'search.degraded' => 'La ricerca è temporaneamente degradata.',
            'search.empty_guidance' =>
'Cerca discussioni pubbliche, risposte, categorie, autori o intervalli di date.',
            'search.empty_title' => 'Cerca nel forum',
            'search.filters'     => 'Filtri',
            'search.from'        => 'Da',
            'search.help'        =>
'I risultati rispettano visibilità, moderazione e permessi correnti.',
            'search.more_results' => 'Mostra altri risultati',
            'search.no_results'   =>
              'Nessun risultato visibile corrisponde alla ricerca.',
            'search.no_results_guidance' =>
'Prova una ricerca più ampia, rimuovi un filtro o controlla la scrittura.',
            'search.pagination'      => 'Paginazione ricerca',
            'search.permission_note' =>
              'Gli estratti includono solo contenuti che puoi leggere.',
            'search.query'           => 'Testo da cercare',
            'search.results'         => 'Risultati ricerca',
            'search.results_summary' => '{count} risultati',
            'search.submit'          => 'Cerca',
            'search.title'           => 'Cerca',
            'search.to'              => 'A',
        },
    };
}

1;
