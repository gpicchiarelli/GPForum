package GPForum::Service::Outbox::DeadLetterRecorder;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $SOURCE_TABLE      => 'outbox_messages';
const my $ID_CONSTRAINT     => 'dead_letters_pkey';
const my $SOURCE_CONSTRAINT => 'idx_dead_letters_source_unique';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Service::Id;
    return GPForum::Service::Id->new;
};
has schema => undef;

sub create_dead_letter {
    my ( $self, $message, $failure ) = @_;

    my $existing = $self->_existing_letter($message);
    if ($existing) {
        return _skipped_letter($existing);
    }

    return $self->_insert_or_reuse_letter( $message, $failure );
}

sub _insert_or_reuse_letter {
    my ( $self, $message, $failure ) = @_;

    my $created = eval { return $self->_insert_letter( $message, $failure ); };
    if ($created) {
        return $created;
    }

    return $self->_letter_after_conflict( $message, $failure, $EVAL_ERROR );
}

sub _letter_after_conflict {
    my ( $self, $message, $failure, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_letter_after_unique( $message, $failure, $error );
}

sub _letter_after_unique {
    my ( $self, $message, $failure, $error ) = @_;

    if ( _letter_id_conflict($error) ) {
        return $self->_letter_after_id_conflict( $message, $failure );
    }
    if ( _letter_source_conflict($error) ) {
        return $self->_reuse_letter_row( $message, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _letter_after_id_conflict {
    my ( $self, $message, $failure ) = @_;

    my $existing = $self->_existing_letter($message);
    if ($existing) {
        return _skipped_letter($existing);
    }

    return $self->_retry_letter_id( $message, $failure );
}

sub _retry_letter_id {
    my ( $self, $message, $failure ) = @_;

    my $created = eval { return $self->_insert_letter( $message, $failure ); };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _reuse_letter_row {
    my ( $self, $message, $error ) = @_;

    my $existing = $self->_existing_letter($message);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return _skipped_letter($existing);
}

sub _letter_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _letter_source_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $SOURCE_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _insert_letter {
    my ( $self, $message, $failure ) = @_;

    my $row = $self->_letter_row( $message, $failure );
    $self->schema->resultset('DeadLetter')->create($row);

    return $row;
}

sub _existing_letter {
    my ( $self, $message ) = @_;

    return $self->schema->resultset('DeadLetter')->find(
        {
            source_id    => $message->get_column('outbox_id'),
            source_table => $SOURCE_TABLE,
        }
    );
}

sub _letter_row {
    my ( $self, $message, $failure ) = @_;

    my $failure_time = $self->clock->now_iso8601;

    return {
        dead_letter_id  => $self->id_service->uuid,
        source_table    => $SOURCE_TABLE,
        source_id       => $message->get_column('outbox_id'),
        payload         => $message->get_column('payload') || {},
        error_class     => $failure->{error_class},
        error_message   => $failure->{error_message},
        failure_type    => $failure->{failure_type} || 'transient',
        retry_count     => $failure->{attempt_count},
        first_failed_at => $message->get_column('first_failed_at')
          || $failure_time,
        last_failed_at => $failure_time,
    };
}

sub _skipped_letter {
    my ($existing) = @_;

    if ( ref $existing eq 'HASH' ) {
        return { %{$existing}, skipped => 1 };
    }

    return { skipped => 1 };
}

1;
