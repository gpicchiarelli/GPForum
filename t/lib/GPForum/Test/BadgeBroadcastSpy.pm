package GPForum::Test::BadgeBroadcastSpy;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has badges => sub { return []; };
has schema => undef;

sub broadcast_notification_badge {
    my ( $self, $user_id, $count ) = @_;

    push @{ $self->badges },
      {
        count          => $count,
        in_transaction => $self->_in_transaction,
        user_id        => $user_id,
      };

    return;
}

sub _in_transaction {
    my ($self) = @_;

    return 0 if !$self->schema;

    return $self->schema->in_transaction ? 1 : 0;
}

1;
