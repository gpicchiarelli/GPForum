# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Outbox::DeadLetterRecorder;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $SOURCE_TABLE      => 'outbox_messages';
const my $ID_CONSTRAINT     => 'dead_letters_pkey';
const my $SOURCE_CONSTRAINT => 'idx_dead_letters_source_unique';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};
has schema => undef;

sub create_dead_letter ( $self, $message, $failure ) {
    my $existing = $self->_existing_letter($message);
    if ($existing) {
        return _skipped_letter($existing);
    }

    return $self->_insert_or_reuse_letter( $message, $failure );
}

sub _insert_or_reuse_letter ( $self, $message, $failure ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_letter( $message, $failure ); },
      );
    if ($created) {
        return $created;
    }

    return $self->_letter_after_conflict( $message, $failure, $error );
}

sub _letter_after_conflict ( $self, $message, $failure, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_letter_after_unique( $message, $failure, $error );
}

sub _letter_after_unique ( $self, $message, $failure, $error ) {
    if ( _letter_id_conflict($error) ) {
        return $self->_letter_after_id_conflict( $message, $failure );
    }
    if ( _letter_source_conflict($error) ) {
        return $self->_reuse_letter_row( $message, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _letter_after_id_conflict ( $self, $message, $failure ) {
    my $existing = $self->_existing_letter($message);
    if ($existing) {
        return _skipped_letter($existing);
    }

    return $self->_retry_letter_id( $message, $failure );
}

sub _retry_letter_id ( $self, $message, $failure ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_letter( $message, $failure ); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _reuse_letter_row ( $self, $message, $error ) {
    my $existing = $self->_existing_letter($message);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return _skipped_letter($existing);
}

sub _letter_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _letter_source_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $SOURCE_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _insert_letter ( $self, $message, $failure ) {
    my $row = $self->_letter_row( $message, $failure );
    $self->schema->resultset('DeadLetter')->create($row);

    return $row;
}

sub _existing_letter ( $self, $message ) {
    return $self->schema->resultset('DeadLetter')->find(
        {
            source_id    => $message->get_column('outbox_id'),
            source_table => $SOURCE_TABLE,
        }
    );
}

sub _letter_row ( $self, $message, $failure ) {
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

sub _skipped_letter ($existing) {
    if ( ref $existing eq 'HASH' ) {
        return { %{$existing}, skipped => 1 };
    }

    return { skipped => 1 };
}

1;
