package GPForum::Test::BadgeBroadcastSpy;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

# Stands in for the realtime notifier the notification dispatcher NOTIFYs
# badges through. It records each badge, and whether a transaction was open
# when it was sent; given a hub, it also delivers the event to it, as the
# listener of every process does with what NOTIFY brings.
has badges => sub { return []; };
has hub    => undef;
has schema => undef;

sub notify {
    my ( $self, $event ) = @_;

    push @{ $self->badges },
      {
        count          => $event->{payload}{unread_count},
        in_transaction => $self->_in_transaction,
        type           => $event->{type},
        user_id        => $event->{aggregate_id},
      };
    if ( $self->hub ) {
        $self->hub->broadcast_event($event);
    }

    return { ok => 1 };
}

sub _in_transaction {
    my ($self) = @_;

    return 0 if !$self->schema;

    return $self->schema->in_transaction ? 1 : 0;
}

1;
