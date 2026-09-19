package GPForum::Test::SubscriberLookup;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has calls    => sub { return []; };
has user_ids => sub { return []; };

sub subscribers_for {
    my ( $self, $target_type, $target_id ) = @_;

    push @{ $self->calls },
      {
        target_id   => $target_id,
        target_type => $target_type,
      };

    return @{ $self->user_ids };
}

1;
