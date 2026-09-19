package GPForum::Service::Realtime::NotificationBadgeReader;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $POST_CREATED       => 'post.created';
const my $POST_SOURCE        => 'post';
const my $REPLY_NOTIFICATION => 'reply';

has schema => undef;

sub badges_for_payload {
    my ( $self, $payload ) = @_;

    my $post_id = _post_id_for_payload($payload);
    return if !$self->schema || !defined $post_id;

    my %unread_count_for;
    for my $user_id ( $self->_notification_recipients_for_post($post_id) ) {
        $unread_count_for{$user_id} = $self->_unread_count_for_user($user_id);
    }

    return %unread_count_for;
}

sub _post_id_for_payload {
    my ($payload) = @_;

    return if !_post_created_payload($payload);

    return _nonempty_value( $payload->{aggregate_id} );
}

sub _post_created_payload {
    my ($payload) = @_;

    return if ref $payload ne 'HASH';

    return ( $payload->{event_type} || q{} ) eq $POST_CREATED ? 1 : 0;
}

sub _nonempty_value {
    my ($value) = @_;

    return if !defined $value;
    return if !length $value;

    return $value;
}

sub _notification_recipients_for_post {
    my ( $self, $post_id ) = @_;

    my $search = eval {
        return $self->schema->resultset('Notification')->search(
            {
                source_type       => $POST_SOURCE,
                source_id         => $post_id,
                notification_type => $REPLY_NOTIFICATION,
            },
            {
                columns  => ['recipient_user_id'],
                group_by => ['recipient_user_id'],
            },
        );
    };
    return if !$search;

    my %seen;
    return grep { defined && !$seen{$_}++ }
      map { _column( $_, 'recipient_user_id' ) } _rows($search);
}

sub _unread_count_for_user {
    my ( $self, $user_id ) = @_;

    my $search = eval {
        return $self->schema->resultset('NotificationInbox')->search(
            {
                recipient_user_id => $user_id,
                read_at           => undef,
            },
            {
                columns => ['notification_id'],
            },
        );
    };
    return 0              if !$search;
    return $search->count if $search->can('count');

    return scalar _rows($search);
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

sub _column {
    my ( $row, $column ) = @_;

    return $row->{$column}           if ref $row eq 'HASH';
    return $row->get_column($column) if $row && $row->can('get_column');

    return;
}

1;
