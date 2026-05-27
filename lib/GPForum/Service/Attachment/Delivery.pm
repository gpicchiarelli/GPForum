package GPForum::Service::Attachment::Delivery;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Service::Attachment::Store;

our $VERSION = '0.001';

has storage => undef;
has store   => sub { return GPForum::Service::Attachment::Store->new; };

sub download {
    my ( $self, $input ) = @_;

    my $decision = $self->store->download_for($input);
    return $decision if !$decision->{ok};

    my $content = $self->storage->read_object( $decision->{object_key} );

    return { %{$decision}, content => $content, };
}

1;
