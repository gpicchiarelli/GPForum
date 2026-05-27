package GPForum::Test::OutboxFailure;

use strict;
use warnings;

use Carp qw(croak);
use overload q{""} => 'message', fallback => 1;

our $VERSION = '0.001';

sub throw {
    my ( $class, $message ) = @_;

    croak bless { message => $message }, $class;
}

sub message {
    my ($self) = @_;

    return $self->{message};
}

1;
