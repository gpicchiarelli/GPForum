package GPForum::Test::OutboxClock;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has now    => '2026-05-23T12:00:00Z';
has future => '2026-05-23T12:01:00Z';

sub now_iso8601 {
    my ($self) = @_;

    return $self->now;
}

sub epoch_plus_iso8601 {
    my ( $self, $seconds ) = @_;

    return $seconds ? $self->future : $self->now;
}

1;
