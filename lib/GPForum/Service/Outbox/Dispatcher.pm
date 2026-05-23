package GPForum::Service::Outbox::Dispatcher;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;
use Try::Tiny;

use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT        => 100;
const my $LOCK_SECONDS         => 60;
const my $PENDING_STATUS       => 'pending';
const my $FAILED_STATUS        => 'failed';
const my $RUNNING_STATUS       => 'running';
const my $DONE_STATUS          => 'done';
const my $GENERIC_ERROR_CLASS  => 'error';
const my $FIRST_FAILURE_OFFSET => 1;

has schema    => undef;
has transport => undef;
has clock     => sub { return GPForum::Service::Clock->new; };
has worker_id => 'worker';

sub dispatch_pending {
    my ( $self, $limit ) = @_;

    my @messages = $self->_ready_messages( $limit || $DEFAULT_LIMIT );
    my %summary  = (
        selected   => scalar @messages,
        dispatched => 0,
        failed     => 0,
    );

    for my $message (@messages) {
        if ( $self->_dispatch_one($message) ) {
            $summary{dispatched} += 1;
        }
        else {
            $summary{failed} += 1;
        }
    }

    return \%summary;
}

sub _ready_messages {
    my ( $self, $limit ) = @_;

    my $search = $self->schema->resultset('OutboxMessage')->search(
        {
            status          => { -in  => [ $PENDING_STATUS, $FAILED_STATUS ] },
            next_attempt_at => { '<=' => $self->clock->now_iso8601 },
        },
        {
            order_by =>
              [ { -asc => 'next_attempt_at' }, { -asc => 'created_at' }, ],
            rows => $limit,
        }
    );

    return _search_rows($search);
}

sub _search_rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

sub _dispatch_one {
    my ( $self, $message ) = @_;

    $self->_mark_running($message);

    my $is_delivered = try {
        $self->transport->dispatch($message);
        return 1;
    }
    catch {
        $self->_mark_failed( $message, $_ );
        return 0;
    };

    if ($is_delivered) {
        $self->_mark_done($message);
    }

    return $is_delivered;
}

sub _mark_running {
    my ( $self, $message ) = @_;

    $message->update(
        {
            status       => $RUNNING_STATUS,
            locked_at    => $self->clock->now_iso8601,
            locked_by    => $self->worker_id,
            locked_until => $self->clock->epoch_plus_iso8601($LOCK_SECONDS),
        }
    );

    return;
}

sub _mark_done {
    my ( $self, $message ) = @_;

    $message->update(
        {
            status           => $DONE_STATUS,
            locked_at        => undef,
            locked_by        => undef,
            locked_until     => undef,
            last_error       => undef,
            last_error_class => undef,
            next_attempt_at  => $self->clock->now_iso8601,
        }
    );

    return;
}

sub _mark_failed {
    my ( $self, $message, $exception ) = @_;

    my $attempt_count = _next_attempt_count($message);

    $message->update(
        {
            status           => $FAILED_STATUS,
            attempts         => $attempt_count,
            attempt_count    => $attempt_count,
            locked_at        => undef,
            locked_by        => undef,
            locked_until     => undef,
            last_error       => "$exception",
            last_error_class => ref $exception || $GENERIC_ERROR_CLASS,
            next_attempt_at  => $self->clock->epoch_plus_iso8601(
                $attempt_count * $LOCK_SECONDS
            ),
        }
    );

    return;
}

sub _next_attempt_count {
    my ($message) = @_;

    my $current = $message->get_column('attempt_count') || 0;

    return $current + $FIRST_FAILURE_OFFSET;
}

1;
