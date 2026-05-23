package GPForum::Worker::Handler::AttachmentScanning;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $ATTACHMENT_UPLOADED => 'attachment.uploaded';

has sink => undef;

sub supports {
    my ( $self, $event ) = @_;

    return $event->{event_type} eq $ATTACHMENT_UPLOADED;
}

sub handle {
    my ( $self, $event ) = @_;

    my $task = {
        action        => 'attachment.scan',
        attachment_id => $event->{aggregate_id},
        event_id      => $event->{event_id},
    };

    if ( $self->sink ) {
        $self->sink->capture($task);
    }

    return $task;
}

1;

