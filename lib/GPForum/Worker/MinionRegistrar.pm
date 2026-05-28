package GPForum::Worker::MinionRegistrar;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $OUTBOX_TASK          => 'gpforum.outbox.dispatch';
const my $SEARCH_TASK          => 'gpforum.search.dispatch';
const my $NOTIFICATION_TASK    => 'gpforum.notification.dispatch';
const my $CACHE_TASK           => 'gpforum.cache_invalidation.dispatch';
const my $ATTACHMENT_SCAN_TASK => 'gpforum.attachment_scan.dispatch';
const my $MEDIA_TASK           => 'gpforum.media_processing.dispatch';
const my $LEGACY_CACHE_TASK    => 'gpforum.cache_invalidation.placeholder';
const my $LEGACY_ATTACHMENT_SCAN_TASK => 'gpforum.attachment_scan.placeholder';
const my $LEGACY_MEDIA_TASK           => 'gpforum.media_processing.placeholder';
const my $DEFAULT_LIMIT               => 100;

has dispatcher         => undef;
has dispatcher_factory => undef;

sub register {
    my ( $self, $minion ) = @_;

    for my $task (
        $OUTBOX_TASK,          $SEARCH_TASK,
        $NOTIFICATION_TASK,    $CACHE_TASK,
        $ATTACHMENT_SCAN_TASK, $MEDIA_TASK,
        $LEGACY_CACHE_TASK,    $LEGACY_ATTACHMENT_SCAN_TASK,
        $LEGACY_MEDIA_TASK,
      )
    {
        $minion->add_task( $task => $self->_dispatch_task );
    }

    return {
        outbox                 => $OUTBOX_TASK,
        search                 => $SEARCH_TASK,
        notification           => $NOTIFICATION_TASK,
        cache                  => $CACHE_TASK,
        attachment_scan        => $ATTACHMENT_SCAN_TASK,
        media                  => $MEDIA_TASK,
        legacy_cache           => $LEGACY_CACHE_TASK,
        legacy_attachment_scan => $LEGACY_ATTACHMENT_SCAN_TASK,
        legacy_media           => $LEGACY_MEDIA_TASK,
    };
}

sub _dispatch_task {
    my ($self) = @_;
    return sub {
        my ( $job, $limit ) = @_;

        my $summary =
          $self->_dispatcher_for($job)
          ->dispatch_pending( $limit || $DEFAULT_LIMIT );
        $job->finish($summary);

        return $summary;
    };
}

sub _dispatcher_for {
    my ( $self, $job ) = @_;

    return $self->dispatcher                 if $self->dispatcher;
    return $self->dispatcher_factory->($job) if $self->dispatcher_factory;

    croak 'outbox dispatcher is required';
}

1;
