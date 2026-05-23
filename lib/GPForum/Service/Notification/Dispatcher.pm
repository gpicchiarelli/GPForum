package GPForum::Service::Notification::Dispatcher;

use strict;
use warnings;

use Const::Fast;
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
has schema             => undef;
has subscription_store => undef;

sub create_notification {
    my ( $self, $input ) = @_;

    return { ok => 0, skipped => 'permission_denied' }
      if !$self->_can_notify($input);

    my $created_at   = $self->clock->now_iso8601;
    my $notification = {
        notification_id   => $self->id_service->uuid,
        recipient_user_id => $input->{recipient_user_id},
        source_type       => $input->{source_type},
        source_id         => $input->{source_id},
        notification_type => $input->{notification_type},
        payload           => $input->{payload} || {},
        created_at        => $created_at,
    };
    my $inbox = {
        recipient_user_id => $input->{recipient_user_id},
        notification_id   => $notification->{notification_id},
        created_at        => $created_at,
        read_at           => undef,
        rank_score        => $input->{rank_score} || $DEFAULT_RANK,
    };

    $self->schema->resultset('Notification')->create($notification);
    $self->schema->resultset('NotificationInbox')->create($inbox);

    return { ok => 1, notification => $notification, inbox => $inbox };
}

sub fanout_to_subscribers {
    my ( $self, $input ) = @_;

    my @recipients =
      $self->subscription_store->subscribers_for( $input->{target_type},
        $input->{target_id}, );
    my @created;

    for my $recipient_user_id (@recipients) {
        my $result = $self->create_notification(
            {
                %{$input}, recipient_user_id => $recipient_user_id,
            }
        );
        if ( $result->{ok} ) {
            push @created, $result;
        }
    }

    return { ok => 1, attempted => scalar @recipients, created => \@created };
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

    my $read_at = $self->clock->now_iso8601;
    my $read    = {
        notification_id   => $notification_id,
        recipient_user_id => $recipient_user_id,
        read_at           => $read_at,
    };

    my $read_resultset  = $self->schema->resultset('NotificationRead');
    my $inbox_resultset = $self->schema->resultset('NotificationInbox');
    $read_resultset->update_or_create($read);
    $inbox_resultset->find(
        {
            notification_id   => $notification_id,
            recipient_user_id => $recipient_user_id,
        }
    )->update( { read_at => $read_at } );

    return $read;
}

sub _can_notify {
    my ( $self, $input ) = @_;

    return 1 if !$self->permission_engine;

    return $self->permission_engine->can_notify(
        $input->{recipient_user_id}, $input->{source_type},
        $input->{source_id},         $input->{payload} || {},
    );
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
            rows => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
