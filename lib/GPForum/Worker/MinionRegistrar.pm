package GPForum::Worker::MinionRegistrar;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $OUTBOX_TASK       => 'gpforum.outbox.dispatch';
const my $SEARCH_TASK       => 'gpforum.search.placeholder';
const my $NOTIFICATION_TASK => 'gpforum.notification.placeholder';
const my $CACHE_TASK        => 'gpforum.cache_invalidation.placeholder';
const my $DEFAULT_LIMIT     => 100;

has dispatcher => undef;

sub register {
    my ( $self, $minion ) = @_;

    $minion->add_task(
        $OUTBOX_TASK => sub {
            my ( $job, $limit ) = @_;

            my $summary =
              $self->dispatcher->dispatch_pending( $limit || $DEFAULT_LIMIT );
            $job->finish($summary);

            return $summary;
        }
    );
    $minion->add_task( $SEARCH_TASK => _placeholder_task('search') );
    $minion->add_task(
        $NOTIFICATION_TASK => _placeholder_task('notification') );
    $minion->add_task( $CACHE_TASK => _placeholder_task('cache') );

    return {
        outbox       => $OUTBOX_TASK,
        search       => $SEARCH_TASK,
        notification => $NOTIFICATION_TASK,
        cache        => $CACHE_TASK,
    };
}

sub _placeholder_task {
    my ($kind) = @_;

    return sub {
        my ($job) = @_;

        my $summary = { ok => 1, placeholder => $kind };
        $job->finish($summary);

        return $summary;
    };
}

1;
