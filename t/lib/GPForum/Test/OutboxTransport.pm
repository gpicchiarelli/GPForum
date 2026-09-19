package GPForum::Test::OutboxTransport;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::OutboxFailure;

our $VERSION = '0.001';

has delivered => sub { return []; };
has fail_ids  => sub { return {}; };

sub dispatch {
    my ( $self, $message ) = @_;

    my $outbox_id = $message->get_column('outbox_id');

    if ( $self->fail_ids->{$outbox_id} ) {
        GPForum::Test::OutboxFailure->throw('boom');
    }

    push @{ $self->delivered }, $outbox_id;

    return;
}

1;
