# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Projection::OffsetTracker;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $CURRENT_STATUS     => 'current';
const my $CATCHING_UP_STATUS => 'catching_up';
const my $FAILED_STATUS      => 'failed';
const my $ZERO_LAG           => 0;

has schema => undef;
has clock  => sub { return GPForum::Service::Clock->new; };

sub record_progress ( $self, $projection_name, $event ) {
    my $existing = $self->_existing_offset($projection_name);
    if ( _same_event( $existing, $event ) ) {
        return _skipped_progress($existing);
    }
    if ($existing) {
        return $self->_refresh_offset(
            $self->_progress_row( $projection_name, $event ) );
    }

    return $self->_insert_or_reuse_offset(
        $self->_progress_row( $projection_name, $event ) );
}

sub _insert_or_reuse_offset ( $self, $row ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_offset($row); },
      );
    if ($created) {
        return $row;
    }

    return $self->_offset_after_conflict( $row, $error );
}

sub _offset_after_conflict ( $self, $row, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    my $existing = $self->_existing_offset( $row->{projection_name} );
    if ( !_same_stored_offset( $existing, $row ) ) {
        return $self->_offset_after_mismatch( $existing, $row, $error );
    }

    return _skipped_progress($existing);
}

sub _offset_after_mismatch ( $self, $existing, $row, $error ) {
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_refresh_offset($row);
}

sub _same_stored_offset ( $existing, $row ) {
    if ( ( $row->{status} || q{} ) eq $FAILED_STATUS ) {
        return _already_failed($existing);
    }

    return _same_text( _column( $existing, 'last_event_id' ),
        $row->{last_event_id} );
}

sub _create_offset ( $self, $row ) {
    return $self->_offsets->create($row);
}

sub _refresh_offset ( $self, $row ) {
    $self->_offsets->update_or_create($row);

    return $row;
}

sub _offsets ($self) {
    return $self->schema->resultset('ProjectionOffset');
}

sub _existing_offset ( $self, $projection_name ) {
    return $self->schema->resultset('ProjectionOffset')->find($projection_name);
}

sub _same_event ( $existing, $event ) {
    if ( !$existing ) {
        return 0;
    }

    return _same_text( _column( $existing, 'last_event_id' ),
        $event->{event_id} );
}

sub _same_text ( $held, $incoming ) {
    return _same_ids( _text($held), _text($incoming) );
}

sub _text ($value) {
    if ( defined $value ) {
        return $value;
    }

    return q{};
}

sub _same_ids ( $held, $incoming ) {
    if ( !length $held ) {
        return 0;
    }
    if ( !length $incoming ) {
        return 0;
    }
    if ( $held eq $incoming ) {
        return 1;
    }

    return 0;
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

sub _progress_row ( $self, $projection_name, $event ) {
    my $lag_seconds = $self->_lag_seconds($event);

    return {
        last_event_created_at => $event->{event_created_at},
        last_event_id         => $event->{event_id},
        lag_seconds           => $lag_seconds,
        projection_name       => $projection_name,
        status                => _status_for_lag($lag_seconds),
        updated_at            => $self->clock->now_iso8601,
    };
}

sub _write_offset ( $self, $row ) {
    my $existing = $self->_existing_offset( $row->{projection_name} );
    if ($existing) {
        return $self->_refresh_offset($row);
    }

    return $self->_insert_or_reuse_offset($row);
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

sub mark_failed ( $self, $projection_name ) {
    my $existing = $self->_existing_offset($projection_name);
    if ( _already_failed($existing) ) {
        return _skipped_progress($existing);
    }

    return $self->_write_offset( $self->_failed_row($projection_name) );
}

sub _already_failed ($existing) {
    if ( !$existing ) {
        return 0;
    }

    my $status = _column( $existing, 'status' ) || q{};
    return $status eq $FAILED_STATUS ? 1 : 0;
}

sub _failed_row ( $self, $projection_name ) {
    return {
        lag_seconds     => $ZERO_LAG,
        projection_name => $projection_name,
        status          => $FAILED_STATUS,
        updated_at      => $self->clock->now_iso8601,
    };
}

sub observe_lag ( $self, $projection_name ) {
    my $row =
      $self->schema->resultset('ProjectionOffset')->find($projection_name);

    my $undefined;
    return $undefined if !$row;

    return {
        projection_name => $row->get_column('projection_name'),
        lag_seconds     => $row->get_column('lag_seconds'),
        status          => $row->get_column('status'),
        updated_at      => $row->get_column('updated_at'),
    };
}

sub _lag_seconds ( $self, $event ) {
    my $event_epoch = $event->{event_created_epoch} || $self->clock->now_epoch;
    my $lag_seconds = $self->clock->now_epoch - $event_epoch;

    return $lag_seconds > $ZERO_LAG ? $lag_seconds : $ZERO_LAG;
}

sub _status_for_lag ($lag_seconds) {
    return $lag_seconds > $ZERO_LAG ? $CATCHING_UP_STATUS : $CURRENT_STATUS;
}

1;
