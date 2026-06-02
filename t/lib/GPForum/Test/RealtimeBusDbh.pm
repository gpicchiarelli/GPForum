package GPForum::Test::RealtimeBusDbh;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $CHANNEL_ARGUMENT => 2;
const my $PAYLOAD_ARGUMENT => 3;

has notifies   => sub { return []; };
has statements => sub { return []; };

sub _dbi_do {
    my ( $self, @arguments ) = @_;

    push @{ $self->statements }, \@arguments;
    $self->_capture_notify(@arguments);

    return 1;
}

sub pg_notifies {
    my ($self) = @_;

    return shift @{ $self->notifies };
}

sub _capture_notify {
    my ( $self, @arguments ) = @_;

    return if $arguments[0] !~ /pg_notify/msx;

    push @{ $self->notifies },
      [ $arguments[$CHANNEL_ARGUMENT], 1, $arguments[$PAYLOAD_ARGUMENT] ];

    return;
}

*GPForum::Test::RealtimeBusDbh::do = \&_dbi_do;

1;
