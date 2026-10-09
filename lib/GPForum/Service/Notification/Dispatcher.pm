# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Notification::Dispatcher;

use Const::Fast;
use Digest::SHA qw(sha1_hex);
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::Keyset;
use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Admin::Settings;
use GPForum::Service::Clock;
use GPForum::Service::Forum::PageWindow;
use GPForum::Service::Forum::SourceThread;
use GPForum::Service::Realtime::EventEnvelope;
use GPForum::Infrastructure::Id;
use GPForum::X::Conflict;
use GPForum::X::Unavailable;

our $VERSION = '0.001';

const my $DEFAULT_RANK  => 0;
const my $DEFAULT_LIMIT => 25;

# The unread count stops here: above it the inbox says "more than 99". Each
# unread row costs a readability lookup, so an uncapped count grew with the
# backlog on every delivery.
const my $UNREAD_CAP                 => 99;
const my $NOTIFICATION_ID_CONSTRAINT => 'notifications_pkey';
const my @CURSOR_COLUMNS             => qw(created_at notification_id);
const my @INBOX_COLUMNS =>
  qw(created_at notification_id rank_score read_at recipient_user_id);
const my $ERROR_TEXT_LIMIT => 300;

# The hex digit groups of a uuid, and the version of one named by a SHA-1.
const my $UUID_GROUPS       => 'A8 A4 A4 A4 A12';
const my $UUID_NAME_VERSION => '5';

# The variant digit keeps its two low bits under the RFC 4122 variant's.
const my $UUID_VARIANT_MASK    => 0x3;
const my $UUID_VARIANT_RFC4122 => 0x8;

# A badge failure is logged at most once in this many seconds per message,
# and this many messages are remembered for it.
const my $BADGE_LOG_INTERVAL => 300;
const my $BADGE_LOG_MESSAGES => 32;

# Bootstrap builds a dispatcher per request, so counters kept on one would
# die with it. These are the process's, shared by every dispatcher it builds,
# as the notifier's are.
my %PROCESS_STATS = ( badge_failures => 0 );

# The last badge failure (for /metrics) and when each message was last
# logged, the process's for the same reason: remembered on a dispatcher, it
# died with its request, and an outage that failed every badge logged a
# warning per request.
my %PROCESS_BADGE_ERRORS;

has badge_errors => sub { return \%PROCESS_BADGE_ERRORS; };
has clock        => sub { return GPForum::Service::Clock->new; };
has event_contract =>
  sub { return GPForum::Service::Realtime::EventEnvelope->new; };
has id_service  => sub { return GPForum::Infrastructure::Id->new; };
has logger      => undef;    # optional: badge failures are dropped without one
has page_window => sub { return GPForum::Service::Forum::PageWindow->new; };
has permission_engine => undef;    # optional: no permission filter
has preference_store  => undef;    # optional: every channel enabled

# Badges go out through NOTIFY (a PgNotifier), never to one process's hub:
# a count changed by a request on one worker reached only the sockets of
# that worker, and a reader's other tabs, on other workers or nodes, kept
# the old one.
has realtime_notifier => undef;    # optional: no realtime badge

# ADR 0102: the inbox and its unread count keep only notifications whose
# source the recipient can still read. One created while a thread was public
# stayed in sight, with its actor and link, after its category turned
# private or the recipient lost their grant.
has readability => undef;    # optional: every source counts as readable
__PACKAGE__->requires(qw(schema));
has subscription_store => undef;    # optional: only fan-out reads it
has stats              => sub { return \%PROCESS_STATS; };

sub create_notification ( $self, $input ) {
    my $engine = $self->permission_engine;
    return { ok => 0, skipped => 'permission_denied' }
      if $engine
      && !$engine->can_notify(
        $input->{recipient_user_id}, $input->{source_type},
        $input->{source_id},         $input->{payload} || {}
      );
    return { ok => 0, skipped => 'channel_disabled', channel => 'in_app' }
      if !$self->_channel_enabled( $input, 'in_app' );

    return $self->_committed_with_badge( $input->{recipient_user_id},
        sub { return $self->_create_notification($input); }, 'delivery' );
}

# The badge is counted once the rows are durable. pg_notify is transactional
# as well: under an outer transaction (a mention inside the command log's)
# PostgreSQL holds the badge until that commits and drops it on rollback, so
# no subscriber holds a count a rollback erased. A delivery that was a
# duplicate sends no badge, though its count is read; a read sends one
# either way.
sub _committed_with_badge ( $self, $recipient_user_id, $work, $delivery = 0 ) {
    my $result =
        $self->schema->can('txn_do')
      ? $self->schema->txn_do($work)
      : $work->();
    return $result if ref $result ne 'HASH' || !$result->{ok};

    $result->{unread_count} = $self->_unread_count( $recipient_user_id,
        !( $delivery && $result->{duplicate} ) );

    return $result;
}

# The delivery writes the notification row and the recipient's inbox row.
# An inbox row already there is answered as a duplicate: it is keyed by
# recipient and notification, so a conflict on it is another delivery of the
# same notification, answered the same way.
sub _create_notification ( $self, $input ) {
    my $idempotency_key = _idempotency_key($input);
    my $notification_id = $input->{notification_id}
      || _notification_id_for($idempotency_key);
    my $inbox_key = {
        notification_id   => $notification_id,
        recipient_user_id => $input->{recipient_user_id},
    };
    my $existing = $self->_find_inbox($inbox_key);
    if ( !$existing ) {
        my $created;
        ( $created, $existing ) = $self->_insert_or_find(
            sub {
                return $self->_insert_delivery( $input, $idempotency_key,
                    $notification_id );
            },
            sub { return $self->_find_inbox($inbox_key); },
        );
        return $created if $created;
    }

    return {
        ok              => 1,
        duplicate       => 1,
        idempotency_key => $idempotency_key,
        notification    => _notification_row(
            $input,
            $idempotency_key,
            _column( $existing, 'notification_id' ),
            _column( $existing, 'created_at' ),
        ),
        inbox => { map { $_ => _column( $existing, $_ ) } @INBOX_COLUMNS },
    };
}

# ADR 0116. notifications_pkey is (notification_id, created_at), so a row
# this delivery left at another time than the clock now reads -- a retry
# after midnight, a slow worker, a leftover from before -- is no conflict:
# the delivery wrote a second row under the same id, and the inbox row,
# joined on both columns, reached only the new one. The id is derived from
# the delivery and carries no time, so the stored row is looked up by id in
# every partition (the primary key's leading column serves the lookup in
# each), and its time, exactly as PostgreSQL returns it, is the one both rows
# use. No lock is needed: two deliveries racing past the lookup both write
# the inbox row, whose key is the recipient and the id alone, and the loser's
# savepoint takes its notification row back with it.
#
# notifications is partitioned by created_at, and PostgreSQL names the
# partition's index in the conflict (notifications_default_pkey,
# notifications_2026_10_pkey), never notifications_pkey itself; `on` reads
# the partitions' index names from the catalog. A notification row another
# delivery stored first is the one this inbox row joins. The unread count
# lands in _committed_with_badge once the write committed.
sub _insert_delivery ( $self, $input, $idempotency_key, $notification_id ) {
    my ($stored) = _rows(
        $self->schema->resultset('Notification')->search_rs(
            { notification_id => $notification_id },
            { columns         => ['created_at'], rows => 1 },
        )
    );
    my $stored_at  = $stored ? _column( $stored, 'created_at' ) : undef;
    my $created_at = $stored_at // $self->clock->now_iso8601;
    my $notification =
      _notification_row( $input, $idempotency_key, $notification_id,
        $created_at );
    my $inbox = {
        created_at        => $created_at,
        notification_id   => $notification_id,
        rank_score        => $input->{rank_score} || $DEFAULT_RANK,
        read_at           => undef,
        recipient_user_id => $input->{recipient_user_id},
    };
    if ( !defined $stored_at ) {
        $self->_insert_or_find(
            sub {
                $self->schema->resultset('Notification')->create($notification);
                return 1;
            },
            sub ($conflict) {
                return $conflict->on($NOTIFICATION_ID_CONSTRAINT);
            },
        );
    }
    $self->schema->resultset('NotificationInbox')->create($inbox);

    return {
        duplicate       => 0,
        idempotency_key => $idempotency_key,
        inbox           => $inbox,
        notification    => $notification,
        ok              => 1,
    };
}

# A row inserted in a savepoint, or else, after a unique conflict, what find
# (told the conflict) answers. Any other error, and a conflict find has
# nothing for, is raised. Returns the insert's value, or undef and find's.
sub _insert_or_find ( $self, $create, $find ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $create );
    return ( $created, undef ) if $created;

    my $conflict = GPForum::X::Conflict->caught($error);
    my $stored   = $conflict ? $find->($conflict) : undef;
    if ( !$stored ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return ( undef, $stored );
}

sub _notification_row ( $input, $idempotency_key, $notification_id,
    $created_at )
{
    return {
        created_at        => $created_at,
        notification_id   => $notification_id,
        notification_type => $input->{notification_type},
        payload           => {
            %{ $input->{payload} || {} }, idempotency_key => $idempotency_key,
        },
        recipient_user_id => $input->{recipient_user_id},
        source_id         => $input->{source_id},
        source_type       => $input->{source_type},
    };
}

sub fanout_to_subscribers ( $self, $input ) {
    my @recipients =
      $self->subscription_store->subscribers_for( $input->{target_type},
        $input->{target_id},
        { notification_type => $input->{notification_type} },
      );
    my $excluded = $input->{excluded_recipient_user_id};
    my %results  = map { $_ => [] } qw(created duplicates failed skipped);

    my $attempted = 0;
    for my $recipient_user_id (@recipients) {
        next if defined $excluded && $recipient_user_id eq $excluded;

        $attempted++;
        my ( $result, $failure );
        try {
            $result = $self->create_notification(
                {
                    %{$input}, recipient_user_id => $recipient_user_id,
                }
            );
        }
        catch ($error) {
            $failure = $error;
        };
        if ( !$result ) {
            push @{ $results{failed} },
              {
                recipient_user_id => $recipient_user_id,
                error             => defined $failure ? "$failure" : q{},
              };
            next;
        }
        my $outcome =
           !$result->{ok}        ? 'skipped'
          : $result->{duplicate} ? 'duplicates'
          :                        'created';
        push @{ $results{$outcome} }, $result;
    }

    return { ok => 1, attempted => $attempted, %results };
}

sub list_for_user ( $self, $user_id, $limit ) {
    return [
        _rows(
            $self->inbox_resultset(
                $user_id, { limit => $limit || $DEFAULT_LIMIT }
            )
        )
    ];
}

sub list_page_for_user ( $self, $user_id, $options ) {
    my $page   = $self->page_window->plan($options);
    my $search = $self->inbox_resultset(
        $user_id,
        {
            %{ $options || {} },
            limit => $page->{fetch_rows},
            after => $page->{after},
        }
    );

    return $self->page_window->page( [ _rows($search) ],
        $page->{limit}, \@CURSOR_COLUMNS );
}

# The id comes from the URL. One that is not a uuid is simply not a
# notification; sent to the uuid column it failed the whole statement, which
# answered 503 and logged an error for a mistyped link.
sub mark_read ( $self, $notification_id, $recipient_user_id ) {
    return $self->_committed_with_badge(
        $recipient_user_id,
        sub {
            return { ok => 0, error => 'not_found' }
              if !GPForum::Infrastructure::Id->is_uuid($notification_id);

            my $inbox = $self->_find_inbox(
                {
                    notification_id   => $notification_id,
                    recipient_user_id => $recipient_user_id,
                }
            );
            return { ok => 0, error => 'not_found' } if !$inbox;

            my $existing_read_at = _column( $inbox, 'read_at' );
            my $read_at = $existing_read_at || $self->clock->now_iso8601;
            my $read    = _read_payload( $inbox, $read_at );
            if ( !$existing_read_at ) {
                $self->_persist_read( $inbox, $read );
            }

            return {
                ok        => 1,
                duplicate => $existing_read_at ? 1 : 0,
                %{$read},
            };
        }
    );
}

# The unread rows the inbox shows are marked: a notification whose source
# the reader can no longer read stays unread and out of sight, and is not
# counted as marked.
sub mark_all_read ( $self, $recipient_user_id ) {
    return $self->_committed_with_badge(
        $recipient_user_id,
        sub {
            my $read_at = $self->clock->now_iso8601;
            my $search =
              $self->schema->resultset('NotificationInbox')->search_rs(
                {
                    'me.read_at'           => undef,
                    'me.recipient_user_id' => $recipient_user_id,
                    %{ $self->_readable_sources( $recipient_user_id, undef ) },
                },
                { join => 'notification' }
              );
            my $marked_count = 0;
            for my $inbox ( _rows($search) ) {
                $self->_persist_read( $inbox,
                    _read_payload( $inbox, $read_at ) );
                $marked_count += 1;
            }

            return {
                duplicate         => $marked_count ? 0 : 1,
                marked_count      => $marked_count,
                ok                => 1,
                read_at           => $read_at,
                recipient_user_id => $recipient_user_id,
            };
        }
    );
}

# The read row is keyed by recipient and notification: a conflict is a read
# another request stored first, whose time this one takes.
sub _persist_read ( $self, $inbox, $read ) {
    my ( undef, $stored ) = $self->_insert_or_find(
        sub {
            return $self->schema->resultset('NotificationRead')->create($read);
        },
        sub {
            return $self->schema->resultset('NotificationRead')
              ->find( { %{$read}{qw(notification_id recipient_user_id)} } );
        },
    );
    if ($stored) {
        $read->{read_at} = _column( $stored, 'read_at' );
    }
    $inbox->update( { read_at => $read->{read_at} } );

    return;
}

sub _read_payload ( $inbox, $read_at ) {
    return {
        notification_id   => _column( $inbox, 'notification_id' ),
        recipient_user_id => _column( $inbox, 'recipient_user_id' ),
        read_at           => $read_at,
    };
}

sub unread_count_for_user ( $self, $user_id, $viewer = undef ) {
    my $search = $self->unread_resultset( $user_id, $viewer );

    return $search->count if $search->can('count');

    return scalar _rows($search);
}

# The unread notifications the badge counts: those the inbox would show.
# Public so tests and the query-plan evidence see the SQL that runs.
sub unread_resultset ( $self, $user_id, $viewer = undef ) {
    return $self->schema->resultset('NotificationInbox')->search_rs(
        {
            'me.recipient_user_id' => $user_id,
            'me.read_at'           => undef,
            %{ $self->_readable_sources( $user_id, $viewer ) },
        },
        {
            columns => ['me.notification_id'],
            join    => 'notification',
            rows    => $UNREAD_CAP + 1,
        }
    );
}

sub _channel_enabled ( $self, $input, $channel ) {
    return 1 if !$self->preference_store;
    return 1
      if !defined $input->{recipient_user_id}
      || !length $input->{recipient_user_id};

    my $enabled;
    try {
        $enabled =
          $self->preference_store->channel_enabled( $input->{recipient_user_id},
            $channel );
    }
    catch ($error) {
        return 1;
    };

    return $enabled ? 1 : 0;
}

# The write has committed when the badge is counted, so the write's answer
# stands whatever happens here. A count that failed was raised past the
# commit: a mark-read that had been stored answered as a failure, and a
# fanout reported a delivered recipient as failed. A failed count or NOTIFY
# is logged and counted instead (the count is undef when it failed), and the
# next snapshot corrects the badge.
#
# Under an outer transaction (a mention inside the command log's) the work
# runs in a savepoint -- attempt is the savepoint helper -- so a statement
# that fails here does not abort the transaction the post still has to
# commit. A NOTIFY the notifier could not send is raised only so that the
# savepoint is rolled back, its statement having perhaps aborted it; the
# count already read is kept.
sub _unread_count ( $self, $user_id, $notify ) {
    my $count;
    my ( undef, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $self->schema,
        sub {
            $count = $self->unread_count_for_user($user_id);
            return 1 if !$notify || !$self->realtime_notifier;

            my $sent = $self->realtime_notifier->notify(
                $self->event_contract->notification_badge( $user_id, $count ) );
            if ( ref $sent eq 'HASH' && !$sent->{ok} ) {
                GPForum::X::Unavailable->throw(
                    message => 'badge NOTIFY failed: '
                      . ( $sent->{reason} || 'unknown' ) );
            }
            return 1;
        },
    );
    if ($error) {
        $self->_badge_failed($error);
    }

    return $count;
}

# Every failure is counted, and kept as the last one for /metrics; it is
# logged once in five minutes per message, not on every badge. In an outage
# every write's badge fails the same way, and a warning per request buried
# the first one under the flood.
#
# A badge that goes out does not re-arm the warning: under load some counts
# still finish, and re-arming on each of them logged nearly every failure of
# the outage. The line logged again says how many failed the same way in
# between, which is all a worker, serving no /metrics, tells of them.
sub _badge_failed ( $self, $error ) {
    my $message = _badge_error_text($error);
    $self->stats->{badge_failures} += 1;
    $self->badge_errors->{last} =
      { at => $self->clock->now_iso8601, message => $message };

    my $logger = $self->logger;
    return if !$logger;

    my $now    = $self->clock->now_epoch;
    my $logged = $self->badge_errors->{logged} //= {};
    my $seen   = $logged->{$message};
    if ( $seen && $now - $seen->{at} < $BADGE_LOG_INTERVAL ) {
        $seen->{suppressed} += 1;
        return;
    }

    my $suppressed = $seen ? $seen->{suppressed} : 0;
    if ( !$seen ) {
        _forget_logged( $logged, $now );
    }
    $logged->{$message} = { at => $now, suppressed => 0 };
    $logger->warn( "notification badge not sent: $message"
          . ( $suppressed ? " ($suppressed more since last logged)" : q{} ) );

    return;
}

# The messages are remembered within a bound: past it the stale ones go,
# and when every one is recent, all of them (each is then logged again).
sub _forget_logged ( $logged, $now ) {
    return if keys %{$logged} < $BADGE_LOG_MESSAGES;

    for my $message ( keys %{$logged} ) {
        if ( $now - $logged->{$message}{at} >= $BADGE_LOG_INTERVAL ) {
            delete $logged->{$message};
        }
    }
    if ( keys %{$logged} >= $BADGE_LOG_MESSAGES ) {
        %{$logged} = ();
    }

    return;
}

# The first line that says something, without the statement DBI appends to
# it: that carries the bind values -- the member's id -- so with it every
# member's badge read as a new message, and /metrics would have shown whose
# count failed. A count that cannot reconnect fails with DBI's connect
# error, which repeats the DSN, an inline password and all: that is
# redacted as the settings page redacts it, before the cut, so the cut
# cannot leave half of it.
sub _badge_error_text ($error) {
    my ($line) = grep { /\S/msx } split /\n/msx, "$error";
    $line //= q{};
    $line =~ s/\s* \[for [ ] Statement [ ] .*\z//msx;
    $line =~ s/\A\s+|\s+\z//gmsx;
    $line = GPForum::Service::Admin::Settings->new->redact( $line, [] );

    return
      length $line > $ERROR_TEXT_LIMIT
      ? substr( $line, 0, $ERROR_TEXT_LIMIT )
      : $line;
}

sub snapshot ($self) {
    my $last_error = $self->badge_errors->{last};
    my %snapshot   = %{ $self->stats };
    $snapshot{last_badge_error} = $last_error ? { %{$last_error} } : undef;

    return \%snapshot;
}

sub _find_inbox ( $self, $query ) {
    return $self->schema->resultset('NotificationInbox')->find($query);
}

# The resultset an inbox page executes.
# Public so the query-plan evidence EXPLAINs what actually runs.
sub inbox_resultset ( $self, $user_id, $options ) {
    my $query = {
        'me.recipient_user_id' => $user_id,
        %{ $self->_readable_sources( $user_id, $options->{viewer} ) },
    };
    if ( $options->{after} ) {
        GPForum::Infrastructure::Keyset->after(
            $query,
            {
                direction => 'desc',
                id   => [ 'me.notification_id', $options->{after}{id} ],
                sort => [ 'me.created_at',      $options->{after}{sort_value} ],
            }
        );
    }

    return $self->schema->resultset('NotificationInbox')->search_rs(
        $query,
        {
            order_by => [
                { -desc => 'me.created_at' },
                { -desc => 'me.notification_id' },
            ],
            prefetch => 'notification',
            GPForum::Service::Forum::SourceThread->attributes(
                $self->readability, 'notification.source_type',
                'notification.source_id'
            ),
            rows => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

# The recipient's own viewer when the request has one; resolved otherwise.
sub _readable_sources ( $self, $user_id, $viewer ) {
    return {} if !$self->readability;

    return {
        -and => [
            $self->readability->sources_condition(
                $viewer // $user_id, 'notification.source_type',
                'notification.source_id'
            )
        ]
    };
}

sub _idempotency_key ($input) {
    return join q{:}, $input->{idempotency_key},
      $input->{recipient_user_id} || q{}
      if defined $input->{idempotency_key};

    my $payload  = $input->{payload}    || {};
    my $event_id = $payload->{event_id} || q{};

    return join q{:},
      'notification',
      $input->{recipient_user_id} || q{},
      $input->{notification_type} || q{},
      $input->{source_type}       || q{},
      $input->{source_id}         || q{},
      $event_id;
}

# A name-based uuid (version 5, SHA-1) of the key: the first 32 hex digits of
# its digest in the 8-4-4-4-12 groups, the third group's first digit the
# version and the fourth's carrying the variant.
sub _notification_id_for ($idempotency_key) {
    my ( $time_low, $time_mid, $version_group, $variant_group, $node ) =
      unpack $UUID_GROUPS, sha1_hex($idempotency_key);
    substr $version_group, 0, 1, $UUID_NAME_VERSION;
    substr $variant_group, 0, 1, _uuid_variant( substr $variant_group, 0, 1 );

    return join q{-}, $time_low, $time_mid, $version_group, $variant_group,
      $node;
}

sub _uuid_variant ($hex_digit) {
    my $value = hex $hex_digit;

    return sprintf '%x',
      ( $value & $UUID_VARIANT_MASK ) | $UUID_VARIANT_RFC4122;
}

sub _column ( $row, $column ) {
    return GPForum::Infrastructure::Row->column( $row, $column );
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Notification::Dispatcher - Delivers notifications to a member's inbox, lists it, marks it read and counts what is unread.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $policy = GPForum::Service::Notification::RecipientPolicy->new(
        schema => $schema );
    my $dispatcher = GPForum::Service::Notification::Dispatcher->new(
        permission_engine  => $policy,
        preference_store   => $preference_store,
        readability        => $policy,
        realtime_notifier  => $pg_notifier,
        schema             => $schema,
        subscription_store => $subscription_store,
    );
    my $delivery = $dispatcher->create_notification(
        {
            recipient_user_id => $user_id,
            notification_type => 'mention',
            source_type       => 'post',
            source_id         => $post_id,
            payload           => { thread_id => $thread_id },
        }
    );
    my $fanout = $dispatcher->fanout_to_subscribers(
        {
            target_type                => 'thread',
            target_id                  => $thread_id,
            source_type                => 'post',
            source_id                  => $post_id,
            notification_type          => 'reply',
            excluded_recipient_user_id => $author_id,
            idempotency_key            => "notification.reply:$event_id",
            payload                    => { event_id => $event_id },
        }
    );
    my $page = $dispatcher->list_page_for_user( $user_id,
        { after => $cursor, limit => 25, viewer => $viewer } );
    $dispatcher->mark_read( $notification_id, $user_id );
    my $unread = $dispatcher->unread_count_for_user( $user_id, $viewer );

=head1 DESCRIPTION

A notification is a C<notifications> row and the recipient's
C<notification_inbox> row; reading it adds a C<notification_reads> row and
stamps the inbox's C<read_at>.

Delivery is idempotent. Each delivery has an idempotency key: the caller's
C<idempotency_key> joined with the recipient, or, without one, the
recipient, type, source and the payload's C<event_id>. Unless the caller
passes a C<notification_id>, the id is a uuid derived from the SHA-1 of
that key, so a retried delivery finds the inbox row it made the first time
and is reported as a C<duplicate> instead of notifying twice. The outbox
relies on this to retry a fan-out safely. Inserts run inside savepoints; a
unique conflict with a concurrent delivery is resolved by reading the row
that won. C<notifications> is partitioned by C<created_at> and keyed on the
id and that time, so a notification row already stored under the id, at
whatever time, is looked up first and reused, its C<created_at> given to
the inbox row (ADR 0116).

A recipient is notified only if the C<permission_engine> agrees (ADR 0102:
only about a source they can read) and their C<in_app> channel is enabled
in the C<preference_store>. The inbox and the unread count keep only
notifications whose source the reader can still read, judged by
C<readability> in the query.

After a delivery or a read commits, the recipient's new unread count is
sent as a C<notification.badge> event through C<realtime_notifier>, a
L<GPForum::Service::Realtime::PgNotifier>, so it reaches the member's
sockets on every node. Under an outer transaction PostgreSQL holds that
NOTIFY until the outer commit. The count is capped: past 99 it stops at
100, which the inbox shows as "more than 99".

The badge comes after the write, and the write's answer stands whatever
happens to it. A count that fails, or a NOTIFY the notifier could not send,
is counted in C<badge_failures>, kept as the C<last_badge_error>, logged
as a warning through C<logger> at most once in five minutes per message,
and left to the next snapshot; the result's C<unread_count> is then undef
when the count itself failed. A badge that goes out in between does not
re-arm the warning, and the line logged again ends with how many failed the
same way since, C<(N more since last logged)>. The message is the error's
first line without the statement and bind values DBI appends, so the
failures of one outage read as one message whoever's badge it was, and with
an inline password (the DSN DBI's connect error repeats) redacted as
L<GPForum::Service::Admin::Settings/redact> redacts it. Under an outer
transaction the count and the NOTIFY run in a savepoint, so a failed
statement there does not abort the transaction the caller still has to
commit.

Every collaborator but C<schema> is optional: without C<permission_engine>
or C<preference_store> everyone is notified, without C<readability> nothing
is filtered, and without C<realtime_notifier> no badge is sent.

=head1 SUBROUTINES/METHODS

=head2 create_notification

Takes a hash reference with C<recipient_user_id>, C<notification_type>,
C<source_type>, C<source_id>, an optional C<payload> hash reference and
optional C<idempotency_key>, C<notification_id> and C<rank_score> (default
0). Returns C<< { ok => 0, skipped => 'permission_denied' } >> when the
C<permission_engine>'s C<can_notify> refuses, and
C<< { ok => 0, skipped => 'channel_disabled', channel => 'in_app' } >> when
the recipient turned the channel off. Otherwise writes the rows in a
transaction and returns C<< { ok => 1, duplicate, idempotency_key,
notification, inbox, unread_count } >>: C<notification> and C<inbox> are
hash references of the stored fields, the notification's C<payload>
carrying the C<idempotency_key>. A notification row already stored under
the id, at any time, is not written again, and both carry its
C<created_at> as PostgreSQL returns it. C<duplicate> is 1 when the recipient
already had this notification; then nothing is written and no badge is
sent, though C<unread_count> is still read. C<unread_count> is undef when
the count failed after the write (see L</DESCRIPTION>).

=head2 fanout_to_subscribers

Takes the same hash reference as C<create_notification>, without
C<recipient_user_id> but with C<target_type> and C<target_id>, whose
subscribers (as the C<subscription_store>'s C<subscribers_for> lists them
for this C<notification_type>) are the recipients, and an optional
C<excluded_recipient_user_id> (the actor) left out. Notifies each in turn;
one that dies does not stop the others. Returns
C<< { ok => 1, attempted, created, duplicates, failed, skipped } >>:
C<attempted> a count, the others array references of the per-recipient
results, C<failed> holding C<< { recipient_user_id, error } >>.

=head2 list_for_user

Takes a user id and a row limit (default 25). Returns an array reference of
the member's C<NotificationInbox> rows, newest first, with their
notification prefetched, judged readable for the member.

=head2 list_page_for_user

Takes a user id and a hash reference with C<after> (the cursor string from
the URL), C<limit> (bounded by L<GPForum::Service::Forum::PageWindow>, 25
by default) and C<viewer> (the reader to judge readability for). Returns
the page hash reference from L<GPForum::Service::Forum::PageWindow/page>:
C<items>, C<has_next> and C<next_cursor>, the cursor over C<created_at>
and C<notification_id>. A cursor that does not decode gives the first
page.

=head2 mark_read

Takes a notification id and the recipient's user id, and marks that
notification read in a transaction. Returns
C<< { ok => 0, error => 'not_found' } >> when the id is not a uuid or the
recipient has no such notification. Otherwise returns
C<< { ok => 1, duplicate, notification_id, recipient_user_id, read_at,
unread_count } >>, with C<duplicate> 1 and the earlier C<read_at> when it
was already read. A badge with the new count is sent in both cases;
C<unread_count> is undef when that count failed after the commit.

=head2 mark_all_read

Takes the recipient's user id and marks every unread notification the
inbox shows read, with one timestamp, in a transaction. Notifications whose
source the member can no longer read stay unread. Returns
C<< { ok => 1, duplicate, marked_count, read_at, recipient_user_id,
unread_count } >>, C<duplicate> being 1 when there was nothing to mark,
and sends a badge; C<unread_count> is undef when that count failed after
the commit.

=head2 snapshot

Returns C<< { badge_failures, last_badge_error } >>: the number of badges
that could not be counted or sent after a write, and the last of those
failures, C<< { at, message } >> (C<at> from the C<clock>), or undef when
there was none. Both are kept per process and shared by every dispatcher it
builds, since Bootstrap builds one per request; the metrics snapshot
reports them as C<notifications>. A test passes its own C<stats> and
C<badge_errors> hash references.

=head2 unread_count_for_user

Takes a user id and an optional viewer (defaults to the user id). Returns
the number of unread notifications the inbox would show, at most 100.

=head2 unread_resultset

Takes a user id and an optional viewer. Returns the unexecuted
C<NotificationInbox> resultset that C<unread_count_for_user> counts: the
member's unread rows with a readable source, only C<notification_id>, at
most 100 rows. Public so tests and the query-plan evidence see the SQL that
runs.

=head2 inbox_resultset

Takes a user id and a hash reference with optional C<viewer>, C<after> (an
already decoded C<< { sort_value, id } >>) and C<limit> (default 25).
Returns the unexecuted C<NotificationInbox> resultset of an inbox page:
the member's notifications with a readable source, ordered by
C<created_at> and then C<notification_id>, descending, with the
notification prefetched. Public so the query-plan evidence EXPLAINs what
runs. When C<readability> is set, each row also carries the thread it is
about, C<source_thread_id> and C<source_thread_title>
(L<GPForum::Service::Forum::SourceThread>).

=head1 DIAGNOSTICS

C<create_notification> croaks with the database error when an insert fails
for any reason other than a unique conflict, or when a conflict on the
inbox leaves no row to reuse; a conflict on the C<notifications> row
itself (C<notifications_pkey>, or the index of the partition PostgreSQL
stored the row in) is accepted, the row being already there.
C<mark_read> and C<mark_all_read> croak likewise when a C<notification_reads>
insert fails and no stored read can be reused. Nothing after the write is
raised: a badge whose count or NOTIFY failed (a NOTIFY the notifier
refused is a L<GPForum::X::Unavailable>, raised only to roll its savepoint
back) is counted in
C<badge_failures> and logged at C<warn> level, C<notification badge not
sent:> and the error's first line (at most 300 characters, without DBI's
C<[for Statement ...]>, an inline password C<[redacted]>), at most once in
five minutes per message, with C<(N more since last logged)> when others
failed the same way in between; the rows are written and the next
snapshot corrects the badge.
C<fanout_to_subscribers> dies when C<subscription_store> is not set. Other
database errors propagate; in a transaction they roll it back.

=head1 CONFIGURATION AND ENVIRONMENT

None. C<clock>, C<id_service>, C<event_contract> and C<page_window> default
to L<GPForum::Service::Clock>, L<GPForum::Infrastructure::Id>,
L<GPForum::Service::Realtime::EventEnvelope> and
L<GPForum::Service::Forum::PageWindow>. C<logger> is optional (anything
with a C<warn> method; Bootstrap passes the application's log, in the web
and the worker processes alike); without it a failed badge is only
counted.

=head1 DEPENDENCIES

L<Const::Fast>, L<Digest::SHA>, L<GPForum::Base>,
L<GPForum::Infrastructure::Id>, L<GPForum::Infrastructure::Keyset>,
L<GPForum::Infrastructure::Row>, L<GPForum::Infrastructure::UniqueConflict>,
L<GPForum::X::Conflict>, L<GPForum::X::Unavailable>,
L<GPForum::Service::Admin::Settings> (its C<redact>), L<GPForum::Service::Clock>,
L<GPForum::Service::Forum::PageWindow>,
L<GPForum::Service::Realtime::EventEnvelope>; passed in:
L<GPForum::Service::Notification::RecipientPolicy> (as C<permission_engine>
and C<readability>), L<GPForum::Service::Notification::PreferenceStore>,
L<GPForum::Service::Notification::SubscriptionStore>,
L<GPForum::Service::Realtime::PgNotifier>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A preference store that dies is read as the channel being enabled. The
counters are per process: C</metrics> reports a web process's, and a worker
process, which serves no C</metrics>, reports its badge failures only in its
log.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
