# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Realtime::NotificationBadgeReader;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Row;

our $VERSION = '0.001';

const my $POST_CREATED       => 'post.created';
const my $POST_SOURCE        => 'post';
const my $REPLY_NOTIFICATION => 'reply';
const my $UNREAD_CAP         => 99;

has schema => undef;

# The badge counts what the inbox shows: notifications whose source the
# recipient can still read (ADR 0102).
has readability => undef;

sub badges_for_payload ( $self, $payload ) {
    my $post_id = _post_id_for_payload($payload);
    return if !$self->schema || !defined $post_id;

    my %unread_count_for;
    for my $user_id ( $self->_notification_recipients_for_post($post_id) ) {
        $unread_count_for{$user_id} = $self->_unread_count_for_user($user_id);
    }

    return %unread_count_for;
}

sub _post_id_for_payload ($payload) {
    my $undefined;
    return $undefined if !_post_created_payload($payload);

    return _nonempty_value( $payload->{aggregate_id} );
}

sub _post_created_payload ($payload) {
    return if ref $payload ne 'HASH';

    return ( $payload->{event_type} || q{} ) eq $POST_CREATED ? 1 : 0;
}

sub _nonempty_value ($value) {
    my $undefined;
    return $undefined if !defined $value;
    return $undefined if !length $value;

    return $value;
}

sub _notification_recipients_for_post ( $self, $post_id ) {
    my $search = eval {
        return $self->schema->resultset('Notification')->search_rs(
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

sub _unread_count_for_user ( $self, $user_id ) {
    my $search = eval {
        return $self->schema->resultset('NotificationInbox')->search_rs(
            {
                'me.recipient_user_id' => $user_id,
                'me.read_at'           => undef,
                %{ $self->_readable_sources($user_id) },
            },
            {
                columns => ['me.notification_id'],
                join    => 'notification',

                # As the inbox: counted up to 100, shown as "more than 99".
                rows => $UNREAD_CAP + 1,
            },
        );
    };
    return 0              if !$search;
    return $search->count if $search->can('count');

    return scalar _rows($search);
}

sub _readable_sources ( $self, $user_id ) {
    return {} if !$self->readability;

    return {
        -and => [
            $self->readability->sources_condition(
                $user_id, 'notification.source_type',
                'notification.source_id'
            )
        ]
    };
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

sub _column ( $row, $column ) {
    return GPForum::Infrastructure::Row->column( $row, $column );
}

1;
