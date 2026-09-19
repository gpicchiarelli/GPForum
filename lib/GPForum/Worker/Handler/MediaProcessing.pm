package GPForum::Worker::Handler::MediaProcessing;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $ATTACHMENT_SCANNED => 'attachment.scanned';

has processor => undef;
has sink      => undef;

sub supports {
    my ( $self, $event ) = @_;

    return $event->{event_type} eq $ATTACHMENT_SCANNED
      && _scan_status($event) eq 'clean';
}

sub handle {
    my ( $self, $event ) = @_;

    my $task = {
        action        => 'media.process',
        attachment_id => $event->{aggregate_id},
        event_id      => $event->{event_id},
    };

    if ( $self->sink ) {
        $self->sink->capture($task);
    }
    if ( $self->processor ) {
        $task->{media} = $self->processor->process( $event->{aggregate_id} );
    }

    return $task;
}

sub _scan_status {
    my ($event) = @_;

    return $event->{scan_status} if defined $event->{scan_status};
    return $event->{domain_payload}{scan_status}
      if defined $event->{domain_payload};

    return q{};
}

1;
