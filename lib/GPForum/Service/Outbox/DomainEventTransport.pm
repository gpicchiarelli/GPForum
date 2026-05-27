package GPForum::Service::Outbox::DomainEventTransport;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has handlers => sub { return []; };

sub dispatch {
    my ( $self, $message ) = @_;

    my $payload = $message->get_column('payload') || {};
    my @results;

    for my $handler ( @{ $self->handlers } ) {
        next if !$handler->supports($payload);

        push @results, $handler->handle($payload);
    }

    return {
        ok       => 1,
        handlers => scalar @results,
        results  => \@results,
    };
}

1;
