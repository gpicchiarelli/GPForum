# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Projection::OffsetTracker;

use Const::Fast;
use List::Util qw(max);
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::X::Conflict;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $CURRENT_STATUS     => 'current';
const my $CATCHING_UP_STATUS => 'catching_up';
const my $FAILED_STATUS      => 'failed';
const my $ZERO_LAG           => 0;
const my $ID_CONSTRAINT      => 'projection_offsets_pkey';

__PACKAGE__->requires(qw(schema));
has clock => sub { return GPForum::Service::Clock->new; };

sub record_progress ( $self, $projection_name, $event ) {
    my $existing = $self->_existing_offset($projection_name);
    if ( $existing
        && _same_id( _column( $existing, 'last_event_id' ), $event->{event_id} )
      )
    {
        return _skipped_progress($existing);
    }

    my $event_epoch = $event->{event_created_epoch} || $self->clock->now_epoch;
    my $lag_seconds = max( $self->clock->now_epoch - $event_epoch, $ZERO_LAG );
    my $status =
      $lag_seconds > $ZERO_LAG ? $CATCHING_UP_STATUS : $CURRENT_STATUS;

    return $self->_write_offset(
        {
            last_event_created_at => $event->{event_created_at},
            last_event_id         => $event->{event_id},
            lag_seconds           => $lag_seconds,
            projection_name       => $projection_name,
            status                => $status,
            updated_at            => $self->clock->now_iso8601,
        },
        $existing
    );
}

sub mark_failed ( $self, $projection_name ) {
    my $existing = $self->_existing_offset($projection_name);
    if ( _already_failed($existing) ) {
        return _skipped_progress($existing);
    }

    return $self->_write_offset(
        {
            lag_seconds     => $ZERO_LAG,
            projection_name => $projection_name,
            status          => $FAILED_STATUS,
            updated_at      => $self->clock->now_iso8601,
        },
        $existing
    );
}

sub observe_lag ( $self, $projection_name ) {
    my $row =
      $self->schema->resultset('ProjectionOffset')->find($projection_name);

    return undef if !$row;

    return {
        projection_name => $row->get_column('projection_name'),
        lag_seconds     => $row->get_column('lag_seconds'),
        status          => $row->get_column('status'),
        updated_at      => $row->get_column('updated_at'),
    };
}

# Writes the row over the stored offset, or inserts it. An insert that loses
# to a concurrent one keeps the winner when it already says the same, and
# writes over it when it does not.
sub _write_offset ( $self, $row, $existing ) {
    my $offsets = $self->schema->resultset('ProjectionOffset');
    if ( !$existing ) {
        my ( $created, $error ) =
          GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
            sub { return $offsets->create($row); } );
        return $row if $created;

        my $conflict = GPForum::X::Conflict->caught($error);
        if ( !$conflict || !$conflict->on($ID_CONSTRAINT) ) {
            GPForum::Infrastructure::UniqueConflict->rethrow($error);
        }
        my $winner = $self->_existing_offset( $row->{projection_name} );
        if ( _same_stored_offset( $winner, $row ) ) {
            return _skipped_progress($winner);
        }
        if ( !$winner ) {
            GPForum::Infrastructure::UniqueConflict->rethrow($error);
        }
    }

    $offsets->update_or_create($row);
    return $row;
}

sub _same_stored_offset ( $existing, $row ) {
    if ( ( $row->{status} || q{} ) eq $FAILED_STATUS ) {
        return _already_failed($existing);
    }

    return _same_id( _column( $existing, 'last_event_id' ),
        $row->{last_event_id} );
}

sub _already_failed ($existing) {
    return 0 if !$existing;

    my $status = _column( $existing, 'status' ) || q{};
    return $status eq $FAILED_STATUS ? 1 : 0;
}

# Two event ids are the same only when both are there and equal.
sub _same_id ( $held, $incoming ) {
    return 0 if !length( $held // q{} ) || !length( $incoming // q{} );

    return $held eq $incoming ? 1 : 0;
}

sub _existing_offset ( $self, $projection_name ) {
    return $self->schema->resultset('ProjectionOffset')->find($projection_name);
}

sub _skipped_progress ($existing) {
    return {
        last_event_created_at => _column( $existing, 'last_event_created_at' ),
        last_event_id         => _column( $existing, 'last_event_id' ),
        lag_seconds           => _column( $existing, 'lag_seconds' ),
        projection_name       => _column( $existing, 'projection_name' ),
        skipped               => 1,
        status                => _column( $existing, 'status' ),
        updated_at            => _column( $existing, 'updated_at' ),
    };
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

1;

__END__

=head1 NAME

GPForum::Service::Projection::OffsetTracker - Where a projection has got to in the event stream, and how far behind it is.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $tracker =
      GPForum::Service::Projection::OffsetTracker->new( schema => $schema );

    $tracker->record_progress(
        'search',
        {
            event_created_at    => $event->{created_at},
            event_created_epoch => $created_epoch,
            event_id            => $event->{event_id},
        }
    );

    my $lag = $tracker->observe_lag('search');
    # { projection_name, lag_seconds, status, updated_at }

    $tracker->mark_failed('search');

=head1 DESCRIPTION

Keeps one C<projection_offsets> row per projection: the last event it
applied, when that event was created, the lag in seconds between then and
now, and a status, C<current> with no lag, C<catching_up> with some, and
C<failed> after C<mark_failed>. Recording the event already recorded, or
failing a projection already failed, writes nothing and returns the stored
row marked as skipped. When two writers insert a projection's first row at
once, the loser keeps the winner's row if it says the same and updates it
otherwise. No method opens a transaction of its own.

=head1 SUBROUTINES/METHODS

=head2 record_progress

Takes a projection name and a hash reference with C<event_id>,
C<event_created_at> and C<event_created_epoch> (now when absent, which
gives no lag). Returns the row written: C<projection_name>,
C<last_event_id>, C<last_event_created_at>, C<lag_seconds> (never
negative), C<status> and C<updated_at>; or the stored row with
C<< skipped => 1 >> when its last event is this one.

=head2 mark_failed

Takes a projection name. Sets its status to C<failed> with a lag of 0 and
returns the row written, or the stored row with C<< skipped => 1 >> when it
had already failed.

=head2 observe_lag

Takes a projection name. Returns
C<< { projection_name, lag_seconds, status, updated_at } >>, or undef when
the projection has no row.

=head1 DIAGNOSTICS

An insert error other than a unique violation, or a unique violation whose
winning row cannot be found, is rethrown with C<croak>; other database
errors propagate.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::Row>, L<GPForum::Infrastructure::UniqueConflict>,
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
