package GPForum::Service::Notification::Dispatcher;

use strict;
use warnings;

use Const::Fast;
use Digest::SHA qw(sha1_hex);
use English     qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Forum::PageWindow;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $DEFAULT_RANK   => 0;
const my $DEFAULT_LIMIT  => 25;
const my @CURSOR_COLUMNS => qw(created_at notification_id);

has clock       => sub { return GPForum::Service::Clock->new; };
has id_service  => sub { return GPForum::Service::Id->new; };
has page_window => sub { return GPForum::Service::Forum::PageWindow->new; };
has permission_engine  => undef;
has realtime_hub       => undef;
has schema             => undef;
has subscription_store => undef;

sub create_notification {
    my ( $self, $input ) = @_;

    return { ok => 0, skipped => 'permission_denied' }
      if !$self->_can_notify($input);

    my $work = sub {
        return $self->_create_notification($input);
    };

    return $self->schema->can('txn_do')
      ? $self->schema->txn_do($work)
      : $work->();
}

sub _create_notification {
    my ( $self, $input ) = @_;

    my $idempotency_key = _idempotency_key($input);
    my $notification_id = $input->{notification_id}
      || _notification_id_for($idempotency_key);
    my $existing = $self->_find_inbox(
        {
            notification_id   => $notification_id,
            recipient_user_id => $input->{recipient_user_id},
        }
    );

    return $self->_duplicate_delivery( $input, $existing, $idempotency_key )
      if $existing;

    return $self->_insert_delivery( $input, $notification_id,
        $idempotency_key );
}

sub _insert_delivery {
    my ( $self, $input, $notification_id, $idempotency_key ) = @_;

    my $created_at   = $self->clock->now_iso8601;
    my $notification = {
        notification_id   => $notification_id,
        recipient_user_id => $input->{recipient_user_id},
        source_type       => $input->{source_type},
        source_id         => $input->{source_id},
        notification_type => $input->{notification_type},
        payload           => {
            %{ $input->{payload} || {} }, idempotency_key => $idempotency_key,
        },
        created_at => $created_at,
    };
    my $inbox = {
        recipient_user_id => $input->{recipient_user_id},
        notification_id   => $notification_id,
        created_at        => $created_at,
        read_at           => undef,
        rank_score        => $input->{rank_score} || $DEFAULT_RANK,
    };

    $self->schema->resultset('Notification')->create($notification);
    $self->schema->resultset('NotificationInbox')->create($inbox);

    my $unread_count =
      $self->_broadcast_unread_count( $input->{recipient_user_id} );

    return {
        ok              => 1,
        duplicate       => 0,
        idempotency_key => $idempotency_key,
        notification    => $notification,
        inbox           => $inbox,
        unread_count    => $unread_count,
    };
}

sub _duplicate_delivery {
    my ( $self, $input, $inbox, $idempotency_key ) = @_;

    my $unread_count =
      $self->unread_count_for_user( $input->{recipient_user_id} );

    return {
        ok              => 1,
        duplicate       => 1,
        idempotency_key => $idempotency_key,
        notification    =>
          _notification_from_inbox( $input, $inbox, $idempotency_key ),
        inbox        => _inbox_hash($inbox),
        unread_count => $unread_count,
    };
}

sub fanout_to_subscribers {
    my ( $self, $input ) = @_;

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

sub list_for_user {
    my ( $self, $user_id, $limit ) = @_;

    my $search = $self->_search_for_user(
        $user_id,
        {
            limit => $limit || $DEFAULT_LIMIT,
        }
    );

    return [ _rows($search) ];
}

sub list_page_for_user {
    my ( $self, $user_id, $options ) = @_;

    my $page   = $self->page_window->plan($options);
    my $search = $self->_search_for_user(
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

sub mark_read {
    my ( $self, $notification_id, $recipient_user_id ) = @_;

    my $work = sub {
        return $self->_mark_read( $notification_id, $recipient_user_id );
    };

    return $self->schema->can('txn_do')
      ? $self->schema->txn_do($work)
      : $work->();
}

sub _mark_read {
    my ( $self, $notification_id, $recipient_user_id ) = @_;

    my $inbox = $self->_find_inbox(
        {
            notification_id   => $notification_id,
            recipient_user_id => $recipient_user_id,
        }
    );

    return { ok => 0, error => 'not_found' } if !$inbox;

    my $existing_read_at = _column( $inbox, 'read_at' );
    my $read_at          = $existing_read_at || $self->clock->now_iso8601;
    my $read             = {
        notification_id   => $notification_id,
        recipient_user_id => $recipient_user_id,
        read_at           => $read_at,
    };

    if ( !$existing_read_at ) {
        $self->schema->resultset('NotificationRead')->update_or_create($read);
        $inbox->update( { read_at => $read_at } );
    }

    my $unread_count = $self->_broadcast_unread_count($recipient_user_id);

    return {
        ok           => 1,
        duplicate    => $existing_read_at ? 1 : 0,
        unread_count => $unread_count,
        %{$read},
    };
}

sub unread_count_for_user {
    my ( $self, $user_id ) = @_;

    my $search = $self->schema->resultset('NotificationInbox')->search(
        {
            recipient_user_id => $user_id,
            read_at           => undef,
        },
        {
            columns => ['notification_id'],
        }
    );

    return $search->count if $search->can('count');

    return scalar _rows($search);
}

sub _can_notify {
    my ( $self, $input ) = @_;

    return 1 if !$self->permission_engine;

    return $self->permission_engine->can_notify(
        $input->{recipient_user_id}, $input->{source_type},
        $input->{source_id},         $input->{payload} || {},
    );
}

sub _broadcast_unread_count {
    my ( $self, $user_id ) = @_;

    my $count = $self->unread_count_for_user($user_id);
    return $count if !$self->realtime_hub;

    $self->realtime_hub->broadcast_notification_badge( $user_id, $count );

    return $count;
}

sub _find_inbox {
    my ( $self, $query ) = @_;

    return $self->schema->resultset('NotificationInbox')->find($query);
}

sub _search_for_user {
    my ( $self, $user_id, $options ) = @_;

    my $query = { recipient_user_id => $user_id };
    if ( $options->{after} ) {
        $query->{-or} = [
            { created_at => { q{<} => $options->{after}{sort_value} } },
            {
                -and => [
                    { created_at      => $options->{after}{sort_value} },
                    { notification_id => { q{<} => $options->{after}{id} } },
                ],
            },
        ];
    }

    return $self->schema->resultset('NotificationInbox')->search(
        $query,
        {
            order_by =>
              [ { -desc => 'created_at' }, { -desc => 'notification_id' } ],
            prefetch => 'notification',
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub _excluded_recipient {
    my ( $recipient_user_id, $input ) = @_;

    return 0 if !defined $input->{excluded_recipient_user_id};

    return $recipient_user_id eq $input->{excluded_recipient_user_id} ? 1 : 0;
}

sub _idempotency_key {
    my ($input) = @_;

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

sub _notification_id_for {
    my ($idempotency_key) = @_;

    my $hex = sha1_hex($idempotency_key);
    substr $hex, 12, 1, '5';
    substr $hex, 16, 1, _uuid_variant( substr $hex, 16, 1 );

    return join q{-}, substr( $hex, 0, 8 ), substr( $hex, 8, 4 ),
      substr( $hex, 12, 4 ), substr( $hex, 16, 4 ), substr( $hex, 20, 12 );
}

sub _uuid_variant {
    my ($hex_digit) = @_;

    my $value = hex $hex_digit;

    return sprintf '%x', ( $value & 0x3 ) | 0x8;
}

sub _notification_from_inbox {
    my ( $input, $inbox, $idempotency_key ) = @_;

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

sub _inbox_hash {
    my ($inbox) = @_;

    return {
        recipient_user_id => _column( $inbox, 'recipient_user_id' ),
        notification_id   => _column( $inbox, 'notification_id' ),
        created_at        => _column( $inbox, 'created_at' ),
        read_at           => _column( $inbox, 'read_at' ),
        rank_score        => _column( $inbox, 'rank_score' ),
    };
}

sub _column {
    my ( $row, $column ) = @_;

    return $row->{$column}           if ref $row eq 'HASH';
    return $row->get_column($column) if $row && $row->can('get_column');

    return;
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
