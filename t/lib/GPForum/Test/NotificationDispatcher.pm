package GPForum::Test::NotificationDispatcher;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has calls => sub { return []; };

sub fanout_to_subscribers {
    my ( $self, $input ) = @_;

    push @{ $self->calls }, $input;

    return {
        ok        => 1,
        attempted => 1,
        created   => [ { notification_id => 'notification-1' } ],
    };
}

1;
