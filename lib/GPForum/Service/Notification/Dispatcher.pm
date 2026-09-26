# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Notification::Dispatcher;

use strict;
use warnings;

use Const::Fast;
use Digest::SHA qw(sha1_hex);
use English     qw(-no_match_vars);
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Keyset;
use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::UniqueConflict;
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

has clock => sub { return GPForum::Service::Clock->new; };
has event_contract =>
  sub { return GPForum::Service::Realtime::EventEnvelope->new; };
has id_service  => sub { return GPForum::Infrastructure::Id->new; };
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
      ? $self->unread_count_for_user($recipient_user_id)
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
    $self->_insert_or_reuse_notification($ctx);
    $self->_create_inbox($ctx);

    return _created_delivery($ctx);
}

sub _fill_delivery_rows ( $self, $ctx ) {
    my $input           = $ctx->{input};
    my $notification_id = $ctx->{notification_id};
    my $created_at      = $self->clock->now_iso8601;
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
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( !_notification_id_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $ctx;
}

sub _notification_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $NOTIFICATION_ID_CONSTRAINT ) >= 0 ? 1 : 0;
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

# A failed NOTIFY leaves the badge to the next snapshot; the rows are written.
sub _broadcast_unread_count ( $self, $user_id ) {
    my $count = $self->unread_count_for_user($user_id);
    return $count if !$self->realtime_notifier;

    $self->realtime_notifier->notify(
        $self->event_contract->notification_badge( $user_id, $count ) );

    return $count;
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
