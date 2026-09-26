# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::UnavailableWrite;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Service::Operations::CommandIdempotency;

our $VERSION = '0.001';

sub assign_report {
    my ($self) = @_;

    return $self->_fail;
}

sub create_suspension {
    my ($self) = @_;

    return $self->_fail;
}

sub revoke_suspension {
    my ($self) = @_;

    return $self->_fail;
}

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

# The workflows reach run() through CommandIdempotency's result_of: run the
# real one, so a regression that turned run()'s failure into a refusal would
# show.
sub result_of {
    my ( $self, $job ) = @_;

    return GPForum::Service::Operations::CommandIdempotency::result_of( $self,
        $job );
}

sub _fail {
    die "DBI connect: could not connect to server\n";
}

1;
