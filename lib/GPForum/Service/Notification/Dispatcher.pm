# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Notification::Dispatcher;

use Const::Fast;
use Digest::SHA qw(sha1_hex);
use English     qw(-no_match_vars);
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Infrastructure::Keyset;
use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Admin::Settings;
use GPForum::Service::Clock;
use GPForum::Service::Forum::PageWindow;
use GPForum::Service::Realtime::EventEnvelope;
use GPForum::Infrastructure::Id;

our $VERSION = '0.001';

const my $DEFAULT_RANK  => 0;
const my $DEFAULT_LIMIT => 25;

# The unread count stops here: above it the inbox says "more than 99". Each
# unread row costs a readability lookup, so an uncapped count grew with the
# backlog on every delivery.
const my $UNREAD_CAP                 => 99;
const my $NOTIFICATION_ID_CONSTRAINT => 'notifications_pkey';
const my @CURSOR_COLUMNS             => qw(created_at notification_id);
const my $ERROR_TEXT_LIMIT           => 300;

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
has logger      => undef;
has page_window => sub { return GPForum::Service::Forum::PageWindow->new; };
has permission_engine => undef;
has preference_store  => undef;

# Badges go out through NOTIFY (a PgNotifier), never to one process's hub:
# a count changed by a request on one worker reached only the sockets of
# that worker, and a reader's other tabs, on other workers or nodes, kept
# the old one.
has realtime_notifier => undef;

# ADR 0102: the inbox and its unread count keep only notifications whose
# source the recipient can still read. One created while a thread was public
# stayed in sight, with its actor and link, after its category turned
# private or the recipient lost their grant.
has readability        => undef;
has schema             => undef;
has stats              => sub { return \%PROCESS_STATS; };
has subscription_store => undef;

sub create_notification ( $self, $input ) {
    return { ok => 0, skipped => 'permission_denied' }
      if !$self->_can_notify($input);
    return { ok => 0, skipped => 'channel_disabled', channel => 'in_app' }
      if !$self->_channel_enabled( $input, 'in_app' );

    my $work = sub {
        return $self->_create_notification($input);
    };

    return $self->_settle_delivery_badge( $self->_committed($work),
        $input->{recipient_user_id} );
}

# The badge is counted once the rows are durable. pg_notify is transactional
# as well: under an outer transaction (a mention inside the command log's)
# PostgreSQL holds the badge until that commits and drops it on rollback, so
# no subscriber holds a count a rollback erased.
sub _committed ( $self, $work ) {
    return $self->schema->can('txn_do')
      ? $self->schema->txn_do($work)
      : $work->();
}

sub _settle_delivery_badge ( $self, $result, $recipient_user_id ) {
    return $result if !_badge_pending($result);

    $result->{unread_count} =
        $result->{duplicate}
      ? $self->_unread_count_after_commit($recipient_user_id)
      : $self->_broadcast_unread_count($recipient_user_id);

    return $result;
}

sub _settle_read_badge ( $self, $result, $recipient_user_id ) {
    return $result if !_badge_pending($result);

    $result->{unread_count} =
      $self->_broadcast_unread_count($recipient_user_id);

    return $result;
}

sub _badge_pending ($result) {
    return 0 if ref $result ne 'HASH';

    return $result->{ok} ? 1 : 0;
}

sub _create_notification ( $self, $input ) {
    my $ctx      = _delivery_ctx($input);
    my $existing = $self->_find_inbox(
        {
            notification_id   => $ctx->{notification_id},
            recipient_user_id => $input->{recipient_user_id},
        }
    );
    if ($existing) {
        return _duplicate_delivery( $input, $existing,
            $ctx->{idempotency_key} );
    }

    return $self->_insert_or_reuse_delivery($ctx);
}

sub _delivery_ctx ($input) {
    my $idempotency_key = _idempotency_key($input);

    return {
        idempotency_key => $idempotency_key,
        input           => $input,
        notification_id => $input->{notification_id}
          || _notification_id_for($idempotency_key),
    };
}

sub _insert_or_reuse_delivery ( $self, $ctx ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_delivery($ctx); },
      );
    if ($created) {
        return $created;
    }

    return $self->_delivery_after_conflict( $ctx, $error );
}

sub _delivery_after_conflict ( $self, $ctx, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    my $existing = $self->_find_inbox(
        {
            notification_id   => $ctx->{notification_id},
            recipient_user_id => $ctx->{input}{recipient_user_id},
        }
    );
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return _duplicate_delivery( $ctx->{input}, $existing,
        $ctx->{idempotency_key} );
}

sub _insert_delivery ( $self, $ctx ) {
    $self->_fill_delivery_rows($ctx);
    if ( !$ctx->{stored} ) {
        $self->_insert_or_reuse_notification($ctx);
    }
    $self->_create_inbox($ctx);

    return _created_delivery($ctx);
}

# ADR 0116. notifications_pkey is (notification_id, created_at), so a row
# this delivery left at another time than the clock now reads -- a retry
# after midnight, a slow worker, a leftover from before -- is no conflict:
# the delivery wrote a second row under the same id, and the inbox row,
# joined on both columns, reached only the new one. The id is derived from
# the delivery and carries no time, so the stored row is looked up by id in
# every partition, and its time is the one both rows use. No lock is needed:
# two deliveries racing past the lookup both write the inbox row, whose key
# is the recipient and the id alone, and the loser's savepoint takes its
# notification row back with it.
sub _fill_delivery_rows ( $self, $ctx ) {
    my $input           = $ctx->{input};
    my $notification_id = $ctx->{notification_id};
    my $stored          = $self->_stored_notification_time($notification_id);
    my $created_at      = $stored // $self->clock->now_iso8601;
    $ctx->{stored}       = defined $stored ? 1 : 0;
    $ctx->{notification} = {
        created_at        => $created_at,
        notification_id   => $notification_id,
        notification_type => $input->{notification_type},
        payload           => {
            %{ $input->{payload} || {} },
            idempotency_key => $ctx->{idempotency_key},
        },
        recipient_user_id => $input->{recipient_user_id},
        source_id         => $input->{source_id},
        source_type       => $input->{source_type},
    };
    $ctx->{inbox} = {
        created_at        => $created_at,
        notification_id   => $notification_id,
        rank_score        => $input->{rank_score} || $DEFAULT_RANK,
        read_at           => undef,
        recipient_user_id => $input->{recipient_user_id},
    };

    return;
}

# The created_at of the notification already stored under this id, in
# whichever partition holds it, exactly as PostgreSQL returns it: the inbox
# row joins on it. The primary key's leading column serves the lookup in
# each partition.
sub _stored_notification_time ( $self, $notification_id ) {
    my $search = $self->schema->resultset('Notification')->search_rs(
        { notification_id => $notification_id },
        { columns         => ['created_at'], rows => 1 },
    );
    my ($stored) = _rows($search);
    return if !$stored;

    return _column( $stored, 'created_at' );
}

sub _insert_or_reuse_notification ( $self, $ctx ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_notification_row($ctx); },
      );
    if ($created) {
        return $created;
    }

    return $self->_notification_after_conflict( $ctx, $error );
}

sub _create_notification_row ( $self, $ctx ) {
    $self->schema->resultset('Notification')->create( $ctx->{notification} );

    return $ctx;
}

sub _notification_after_conflict ( $self, $ctx, $error ) {
    if ( !$self->_notification_id_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $ctx;
}

# notifications is partitioned by created_at, and PostgreSQL names the
# partition's index in the conflict (notifications_default_pkey,
# notifications_2026_10_pkey), never notifications_pkey itself: matched on
# that name alone, a leftover notification row was rethrown on PostgreSQL and
# its delivery died where it should complete.
sub _notification_id_conflict ( $self, $error ) {
    return GPForum::Infrastructure::UniqueConflict->is_conflict_on(
        $self->schema, $error, $NOTIFICATION_ID_CONSTRAINT );
}

sub _create_inbox ( $self, $ctx ) {
    $self->schema->resultset('NotificationInbox')->create( $ctx->{inbox} );

    return $ctx;
}

# The unread count lands in _settle_delivery_badge once the write committed.
sub _created_delivery ($ctx) {
    return {
        duplicate       => 0,
        idempotency_key => $ctx->{idempotency_key},
        inbox           => $ctx->{inbox},
        notification    => $ctx->{notification},
        ok              => 1,
    };
}

sub _duplicate_delivery ( $input, $inbox, $idempotency_key ) {
    return {
        ok              => 1,
        duplicate       => 1,
        idempotency_key => $idempotency_key,
        notification    =>
          _notification_from_inbox( $input, $inbox, $idempotency_key ),
        inbox => _inbox_hash($inbox),
    };
}

sub fanout_to_subscribers ( $self, $input ) {
    my @recipients =
      $self->subscription_store->subscribers_for( $input->{target_type},
        $input->{target_id},
        { notification_type => $input->{notification_type} },
      );
    my @created;
    my @failed;
    my @duplicates;
    my @skipped;

    my $attempted = 0;
    for my $recipient_user_id (@recipients) {
        next if _excluded_recipient( $recipient_user_id, $input );

        $attempted++;
        my $result = eval {
            return $self->create_notification(
                {
                    %{$input}, recipient_user_id => $recipient_user_id,
                }
            );
        };
        if ( !$result ) {
            push @failed,
              {
                recipient_user_id => $recipient_user_id,
                error             => "$EVAL_ERROR",
              };
            next;
        }
        if ( $result->{ok} && $result->{duplicate} ) {
            push @duplicates, $result;
        }
        elsif ( $result->{ok} ) {
            push @created, $result;
        }
        else {
            push @skipped, $result;
        }
    }

    return {
        ok         => 1,
        attempted  => $attempted,
        created    => \@created,
        duplicates => \@duplicates,
        failed     => \@failed,
        skipped    => \@skipped,
    };
}

sub list_for_user ( $self, $user_id, $limit ) {
    my $search = $self->inbox_resultset(
        $user_id,
        {
            limit => $limit || $DEFAULT_LIMIT,
        }
    );

    return [ _rows($search) ];
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

    my @rows = _rows($search);

    return $self->page_window->page( \@rows, $page->{limit}, \@CURSOR_COLUMNS );
}

sub mark_read ( $self, $notification_id, $recipient_user_id ) {
    my $work = sub {
        return $self->_mark_read( $notification_id, $recipient_user_id );
    };

    return $self->_settle_read_badge( $self->_committed($work),
        $recipient_user_id );
}

sub _mark_read ( $self, $notification_id, $recipient_user_id ) {

    # The id comes from the URL. One that is not a uuid is simply not a
    # notification; sent to the uuid column it failed the whole statement,
    # which answered 503 and logged an error for a mistyped link.
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
    my $read_at          = $existing_read_at || $self->clock->now_iso8601;
    my $read             = _read_payload( $inbox, $read_at );

    if ( !$existing_read_at ) {
        $self->_persist_read( $inbox, $read );
    }

    return {
        ok        => 1,
        duplicate => $existing_read_at ? 1 : 0,
        %{$read},
    };
}

sub mark_all_read ( $self, $recipient_user_id ) {
    my $work = sub {
        return $self->_mark_all_read($recipient_user_id);
    };

    return $self->_settle_read_badge( $self->_committed($work),
        $recipient_user_id );
}

sub _mark_all_read ( $self, $recipient_user_id ) {
    my $read_at      = $self->clock->now_iso8601;
    my $marked_count = $self->_mark_unread_rows( $recipient_user_id, $read_at );

    return {
        duplicate         => $marked_count ? 0 : 1,
        marked_count      => $marked_count,
        ok                => 1,
        read_at           => $read_at,
        recipient_user_id => $recipient_user_id,
    };
}

sub _mark_unread_rows ( $self, $recipient_user_id, $read_at ) {
    my $count = 0;
    for my $inbox ( @{ $self->_unread_inbox_rows($recipient_user_id) } ) {
        $self->_persist_read( $inbox, _read_payload( $inbox, $read_at ) );
        $count += 1;
    }

    return $count;
}

# The unread rows the inbox shows: a notification whose source the reader
# can no longer read stays unread and out of sight, and is not counted as
# marked.
sub _unread_inbox_rows ( $self, $recipient_user_id ) {
    my $search = $self->schema->resultset('NotificationInbox')->search_rs(
        {
            'me.read_at'           => undef,
            'me.recipient_user_id' => $recipient_user_id,
            %{ $self->_readable_sources( $recipient_user_id, undef ) },
        },
        { join => 'notification' }
    );

    return [ _rows($search) ];
}

sub _persist_read ( $self, $inbox, $read ) {
    $self->_insert_or_reuse_read($read);
    $inbox->update( { read_at => $read->{read_at} } );

    return;
}

sub _insert_or_reuse_read ( $self, $read ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_read($read); },
      );
    if ($created) {
        return;
    }

    return $self->_read_after_conflict( $read, $error );
}

sub _create_read ( $self, $read ) {
    return $self->schema->resultset('NotificationRead')->create($read);
}

sub _read_after_conflict ( $self, $read, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_reuse_read( $read, $error );
}

sub _reuse_read ( $self, $read, $error ) {
    my $stored = $self->schema->resultset('NotificationRead')->find(
        {
            notification_id   => $read->{notification_id},
            recipient_user_id => $read->{recipient_user_id},
        }
    );
    if ( !$stored ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    $read->{read_at} = _column( $stored, 'read_at' );

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

sub _can_notify ( $self, $input ) {
    return 1 if !$self->permission_engine;

    return $self->permission_engine->can_notify(
        $input->{recipient_user_id}, $input->{source_type},
        $input->{source_id},         $input->{payload} || {},
    );
}

sub _channel_enabled ( $self, $input, $channel ) {
    return 1 if !$self->preference_store;
    return 1
      if !defined $input->{recipient_user_id}
      || !length $input->{recipient_user_id};

    my $enabled = eval {
        return $self->preference_store->channel_enabled(
            $input->{recipient_user_id}, $channel );
    };
    return 1 if $EVAL_ERROR;

    return $enabled ? 1 : 0;
}

# The write has committed when the badge is counted, so the write's answer
# stands whatever happens here. A count that failed was raised past the
# commit: a mark-read that had been stored answered as a failure, and a
# fanout reported a delivered recipient as failed. A failed count or NOTIFY
# is logged and counted instead (unread_count is undef when the count
# failed), and the next snapshot corrects the badge.
#
# Under an outer transaction (a mention inside the command log's) the work
# runs in a savepoint -- attempt is the savepoint helper -- so a statement
# that fails here does not abort the transaction the post still has to
# commit.
sub _broadcast_unread_count ( $self, $user_id ) {
    my $count;
    my ( undef, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $self->schema,
        sub {
            $count = $self->unread_count_for_user($user_id);
            return $self->_notify_badge( $user_id, $count );
        },
    );
    if ($error) {
        $self->_badge_failed($error);
    }

    return $count;
}

sub _unread_count_after_commit ( $self, $user_id ) {
    my ( $count, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->unread_count_for_user($user_id); },
      );
    if ($error) {
        return $self->_badge_failed($error);
    }

    return $count;
}

# A NOTIFY the notifier could not send is raised here only so that the
# savepoint is rolled back, its statement having perhaps aborted it; the
# count already read is kept.
sub _notify_badge ( $self, $user_id, $count ) {
    return 1 if !$self->realtime_notifier;

    my $sent = $self->realtime_notifier->notify(
        $self->event_contract->notification_badge( $user_id, $count ) );
    if ( ref $sent eq 'HASH' && !$sent->{ok} ) {
        die 'badge NOTIFY failed: ' . ( $sent->{reason} || 'unknown' ) . "\n";
    }

    return 1;
}

# Every failure is counted, and kept as the last one for /metrics; it is
# logged once in five minutes per message, not on every badge. In an outage
# every write's badge fails the same way, and a warning per request buried
# the first one under the flood.
sub _badge_failed ( $self, $error ) {
    my $message = _badge_error_text($error);

    $self->stats->{badge_failures} += 1;
    $self->badge_errors->{last} =
      { at => $self->clock->now_iso8601, message => $message };
    $self->_log_badge_failure($message);

    return undef;
}

# A badge that goes out does not re-arm the warning: under load some counts
# still finish, and re-arming on each of them logged nearly every failure of
# the outage. The line logged again says how many failed the same way in
# between, which is all a worker, serving no /metrics, tells of them.
sub _log_badge_failure ( $self, $message ) {
    my $logger = $self->logger;
    return if !$logger || !$logger->can('warn');

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
            rows     => $options->{limit} || $DEFAULT_LIMIT,
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

sub _excluded_recipient ( $recipient_user_id, $input ) {
    return 0 if !defined $input->{excluded_recipient_user_id};

    return $recipient_user_id eq $input->{excluded_recipient_user_id} ? 1 : 0;
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

sub _notification_id_for ($idempotency_key) {
    my $hex = sha1_hex($idempotency_key);
    substr $hex, 12, 1, '5';
    substr $hex, 16, 1, _uuid_variant( substr $hex, 16, 1 );

    return join q{-}, substr( $hex, 0, 8 ), substr( $hex, 8, 4 ),
      substr( $hex, 12, 4 ), substr( $hex, 16, 4 ), substr( $hex, 20, 12 );
}

sub _uuid_variant ($hex_digit) {
    my $value = hex $hex_digit;

    return sprintf '%x', ( $value & 0x3 ) | 0x8;
}

sub _notification_from_inbox ( $input, $inbox, $idempotency_key ) {
    return {
        notification_id   => _column( $inbox, 'notification_id' ),
        recipient_user_id => $input->{recipient_user_id},
        source_type       => $input->{source_type},
        source_id         => $input->{source_id},
        notification_type => $input->{notification_type},
        payload           => {
            %{ $input->{payload} || {} }, idempotency_key => $idempotency_key,
        },
        created_at => _column( $inbox, 'created_at' ),
    };
}

sub _inbox_hash ($inbox) {
    return {
        recipient_user_id => _column( $inbox, 'recipient_user_id' ),
        notification_id   => _column( $inbox, 'notification_id' ),
        created_at        => _column( $inbox, 'created_at' ),
        read_at           => _column( $inbox, 'read_at' ),
        rank_score        => _column( $inbox, 'rank_score' ),
    };
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
runs.

=head1 DIAGNOSTICS

C<create_notification> croaks with the database error when an insert fails
for any reason other than a unique conflict, or when a conflict on the
inbox leaves no row to reuse; a conflict on the C<notifications> row
itself (C<notifications_pkey>, or the index of the partition PostgreSQL
stored the row in) is accepted, the row being already there.
C<mark_read> and C<mark_all_read> croak likewise when a C<notification_reads>
insert fails and no stored read can be reused. Nothing after the write is
raised: a badge whose count or NOTIFY failed is counted in
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

L<Const::Fast>, L<Digest::SHA>, L<Mojo::Base>,
L<GPForum::Infrastructure::Id>, L<GPForum::Infrastructure::Keyset>,
L<GPForum::Infrastructure::Row>, L<GPForum::Infrastructure::UniqueConflict>,
L<GPForum::Service::Admin::Settings> (its C<redact>),
L<GPForum::Service::Clock>, L<GPForum::Service::Forum::PageWindow>,
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
