package GPForum::Worker::Handler::AttachmentScanning;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Service::Attachment::Validator;

our $VERSION = '0.001';

const my $ATTACHMENT_UPLOADED => 'attachment.uploaded';
const my $SCANNER_ACTOR       => 'attachment-scanner';
const my $SCAN_CLEAN          => 'clean';
const my $SCAN_FAILED         => 'failed';
const my $SCAN_INFECTED       => 'infected';

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
    if ( !$attachment ) {
        return { error => 'not_found', ok => 0 };
    }

    my $replayed = $self->store->terminal_scan($attachment);
    if ($replayed) {
        return $replayed;
    }

    return $self->_scan_bytes( $attachment, $attachment_id );
}

sub _scan_bytes {
    my ( $self, $attachment, $attachment_id ) = @_;

    my $content = $self->_read_object($attachment);
    if ( !defined $content ) {
        return $self->_failed_read($attachment_id);
    }

    return $self->store->record_scan(
        $self->_scan_input( $attachment, $content ) );
}

sub _read_object {
    my ( $self, $attachment ) = @_;

    my $content = eval {
        return $self->storage->read_object(
            $self->store->record->column( $attachment, 'object_key' ) );
    };
    if ($EVAL_ERROR) {
        return;
    }

    return $content;
}

sub _failed_read {
    my ( $self, $attachment_id ) = @_;

    return $self->store->record_scan(
        {
            actor_id      => $SCANNER_ACTOR,
            attachment_id => $attachment_id,
            reason        => 'object read failed',
            scan_status   => $SCAN_FAILED,
        }
    );
}

sub _scan_input {
    my ( $self, $attachment, $content ) = @_;

    my $scan_status = $self->_scan_status( $attachment, $content );

    return {
        actor_id      => $SCANNER_ACTOR,
        attachment_id =>
          $self->store->record->column( $attachment, 'attachment_id' ),
        reason      => _scan_reason($scan_status),
        scan_status => $scan_status,
    };
}

sub _scan_status {
    my ( $self, $attachment, $content ) = @_;

    if ( $self->_same_media( $attachment, $content ) ) {
        return $SCAN_CLEAN;
    }

    return $SCAN_INFECTED;
}

sub _same_media {
    my ( $self, $attachment, $content ) = @_;

    my $sniffed = $self->validator->sniff_media_type($content);
    my $stored  = $self->store->record->column( $attachment, 'media_type' );
    if ( _text($sniffed) eq _text($stored) ) {
        return 1;
    }

    return 0;
}

sub _scan_reason {
    my ($scan_status) = @_;

    if ( $scan_status eq $SCAN_CLEAN ) {
        return;
    }

    return 'media mismatch';
}

sub _text {
    my ($value) = @_;

    if ( defined $value ) {
        return $value;
    }

    return q{};
}

1;
