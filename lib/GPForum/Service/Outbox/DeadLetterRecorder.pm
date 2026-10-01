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

__END__

=head1 NAME

GPForum::Service::Outbox::DeadLetterRecorder - Copy an outbox message that will not be retried into dead_letters, once.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $recorder = GPForum::Service::Outbox::DeadLetterRecorder->new(
        schema => $schema,
    );
    my $letter = $recorder->create_dead_letter(
        $outbox_message_row,
        {
            attempt_count => 5,
            error_class   => 'smtp_timeout',
            error_message => $error,
            failure_type  => 'transient',
        }
    );
    # $letter->{skipped} is true when the message was already dead-lettered

=head1 DESCRIPTION

When L<GPForum::Service::Outbox::Dispatcher> gives up on an outbox message,
this class writes a C<dead_letters> row that keeps the message's payload and
the last failure, so an operator can inspect and replay it. There is at most
one dead letter per outbox message: the row is keyed by the source table
(C<outbox_messages>) and the message's C<outbox_id>, and a unique index
backs that rule. Each insert runs under a savepoint through
L<GPForum::Infrastructure::UniqueConflict>, so a conflict does not abort the
caller's transaction.

When the insert hits the source unique index (another worker recorded the
same message first), the existing row is reused. When it hits the primary
key (a generated id that was already taken), the existing letter is looked
up again and, if there is none, the insert is retried once with a fresh id.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor. C<schema> is required; C<clock> and C<id_service>
default to L<GPForum::Service::Clock> and L<GPForum::Infrastructure::Id>.

=head2 create_dead_letter

Takes the outbox message row (an object with C<get_column>; its
C<outbox_id>, C<payload> and C<first_failed_at> are read) and a failure hash
reference with C<attempt_count>, C<error_class>, C<error_message> and an
optional C<failure_type> (C<transient> when absent).

Returns the hash of the row it inserted (C<dead_letter_id>,
C<source_table>, C<source_id>, C<payload>, C<error_class>,
C<error_message>, C<failure_type>, C<retry_count>, C<first_failed_at>,
C<last_failed_at>). C<first_failed_at> falls back to the current time when
the message has none; C<last_failed_at> is the current time.

When a dead letter for the message already exists, nothing is written and
it returns a hash reference with C<skipped> set to 1 (merged into the
existing record when that record is a plain hash).

=head1 DIAGNOSTICS

Croaks with the database error when the insert fails for a reason other
than one of the two unique constraints, when the retried insert fails, or
when the source constraint fires but no existing row can be found.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::Infrastructure::Id>,
L<GPForum::Service::Clock>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
