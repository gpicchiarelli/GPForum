package GPForum::Test::NotificationDispatcher;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has calls         => sub { return []; };
has notifications => sub { return []; };

sub create_notification {
    my ( $self, $input ) = @_;

    if ( $self->_delivered($input) ) {
        return { duplicate => 1, inbox => {}, ok => 1 };
    }

    push @{ $self->notifications }, $input;

    return {
        duplicate    => 0,
        inbox        => {},
        ok           => 1,
        notification => {
            notification_id   => 'notification-mention-1',
            notification_type => $input->{notification_type},
            payload           => $input->{payload} || {},
            recipient_user_id => $input->{recipient_user_id},
        },
    };
}

sub _delivered {
    my ( $self, $input ) = @_;

    my $key = _delivery_key($input);
    for my $existing ( @{ $self->notifications } ) {
        if ( _delivery_key($existing) eq $key ) {
            return 1;
        }
    }

    return 0;
}

sub _delivery_key {
    my ($input) = @_;

    return join q{:}, $input->{notification_type} || q{},
      $input->{recipient_user_id} || q{},
      $input->{source_id}         || q{},
      $input->{source_type}       || q{};
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
