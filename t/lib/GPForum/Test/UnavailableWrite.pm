package GPForum::Test::UnavailableWrite;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub create_post {
    my ($self) = @_;

    return $self->_fail;
}

sub create_report {
    my ($self) = @_;

    return $self->_fail;
}

sub hide_post {
    my ($self) = @_;

    return $self->_fail;
}

sub mark_thread_read {
    my ($self) = @_;

    return $self->_fail;
}

sub request_user_export {
    my ($self) = @_;

    return $self->_fail;
}

sub run {
    my ($self) = @_;

    return $self->_fail;
}

sub _fail {
    die "DBI connect: could not connect to server\n";
}

1;
