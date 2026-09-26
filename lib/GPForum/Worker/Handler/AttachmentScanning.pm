# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Worker::Handler::AttachmentScanning;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Service::Attachment::Scanner;

our $VERSION = '0.001';

const my $ATTACHMENT_UPLOADED => 'attachment.uploaded';

# The system antivirus (ADR 0108), or undef when scanning is off.
has antivirus => undef;
has sink      => undef;
has storage   => undef;
has store     => undef;
has scanner   => sub ($self) {
    return GPForum::Service::Attachment::Scanner->new(
        antivirus => $self->antivirus,
        storage   => $self->storage,
        store     => $self->store,
    );
};

sub supports ( $self, $event ) {
    return $event->{event_type} eq $ATTACHMENT_UPLOADED;
}

sub handle ( $self, $event ) {
    my $task = {
        action        => 'attachment.scan',
        attachment_id => $event->{aggregate_id},
        event_id      => $event->{event_id},
    };

    if ( $self->sink ) {
        $self->sink->capture($task);
    }
    if ( $self->store && $self->storage ) {
        $task->{scan} = $self->scanner->scan( $event->{aggregate_id} );
    }

    return $task;
}

1;
