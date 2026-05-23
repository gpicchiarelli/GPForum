package GPForum::Service::Outbox::DeadLetterRecorder;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $SOURCE_TABLE => 'outbox_messages';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub create_dead_letter {
    my ( $self, $message, $failure ) = @_;

    my $failure_time = $self->clock->now_iso8601;
    my $row          = {
        dead_letter_id  => $self->id_service->uuid,
        source_table    => $SOURCE_TABLE,
        source_id       => $message->get_column('outbox_id'),
        payload         => $message->get_column('payload') || {},
        error_class     => $failure->{error_class},
        error_message   => $failure->{error_message},
        retry_count     => $failure->{attempt_count},
        first_failed_at => $message->get_column('first_failed_at')
          || $failure_time,
        last_failed_at => $failure_time,
    };

    $self->schema->resultset('DeadLetter')->create($row);

    return $row;
}

1;
