package GPForum::Test::NotificationDispatcher;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has calls         => sub { return []; };
has notifications => sub { return []; };

sub create_notification {
    my ( $self, $input ) = @_;

    push @{ $self->notifications }, $input;

    return {
        ok           => 1,
        notification => {
            notification_id   => 'notification-mention-1',
            recipient_user_id => $input->{recipient_user_id},
            notification_type => $input->{notification_type},
            payload           => $input->{payload} || {},
        },
        inbox => {},
    };
}

sub fanout_to_subscribers {
    my ( $self, $input ) = @_;

    push @{ $self->calls }, $input;

    return {
        ok         => 1,
        attempted  => 1,
        created    => [ { notification_id => 'notification-1' } ],
        duplicates => [],
        failed     => [],
        skipped    => [],
    };
}

1;
