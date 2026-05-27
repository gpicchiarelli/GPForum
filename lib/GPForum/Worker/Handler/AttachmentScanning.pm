package GPForum::Worker::Handler::AttachmentScanning;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Service::Attachment::Validator;

our $VERSION = '0.001';

const my $ATTACHMENT_UPLOADED => 'attachment.uploaded';

has sink      => undef;
has storage   => undef;
has store     => undef;
has validator => sub { return GPForum::Service::Attachment::Validator->new; };

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
    if ( $self->store && $self->storage ) {
        $task->{scan} = $self->_scan_attachment( $event->{aggregate_id} );
    }

    return $task;
}

sub _scan_attachment {
    my ( $self, $attachment_id ) = @_;

    my $attachment = $self->store->find_attachment($attachment_id);
    return { ok => 0, error => 'not_found' } if !$attachment;

    my $content = eval {
        return $self->storage->read_object(
            $attachment->get_column('object_key') );
    };
    if ($EVAL_ERROR) {
        return $self->store->record_scan(
            {
                actor_id      => 'attachment-scanner',
                attachment_id => $attachment_id,
                reason        => 'object read failed',
                scan_status   => 'failed',
            }
        );
    }

    my $media_type = $self->validator->sniff_media_type($content);
    my $scan_status =
      ( $media_type || q{} ) eq ( $attachment->get_column('media_type') || q{} )
      ? 'clean'
      : 'infected';

    return $self->store->record_scan(
        {
            actor_id      => 'attachment-scanner',
            attachment_id => $attachment_id,
            reason        => $scan_status eq 'clean' ? undef : 'media mismatch',
            scan_status   => $scan_status,
        }
    );
}

1;
