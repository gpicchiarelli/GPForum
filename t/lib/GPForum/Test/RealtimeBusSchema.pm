# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RealtimeBusSchema;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

use GPForum::Test::RealtimeBusStorage;

our $VERSION = '0.001';

has dbh                          => undef;
has notification_inbox_resultset => undef;
has notification_resultset       => undef;
has outbox_resultset             => undef;

sub storage {
    my ($self) = @_;

    return GPForum::Test::RealtimeBusStorage->new( dbh => $self->dbh );
}

sub resultset {
    my ( $self, $name ) = @_;

    my $resultset = $self->_resultset_for($name);
    return $resultset if $resultset;

    croak "unexpected resultset $name";
}

sub _resultset_for {
    my ( $self, $name ) = @_;

    my %resultset_for = (
        Notification      => $self->notification_resultset,
        NotificationInbox => $self->notification_inbox_resultset,
        OutboxMessage     => $self->outbox_resultset,
    );

    return $resultset_for{$name};
}

1;
