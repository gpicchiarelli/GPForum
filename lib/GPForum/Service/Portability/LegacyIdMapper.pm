# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Portability::LegacyIdMapper;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Infrastructure::Id;

our $VERSION = '0.001';

const my $ID_CONSTRAINT     => 'legacy_id_map_pkey';
const my $SOURCE_CONSTRAINT => 'legacy_id_map_source_key';
const my $ROW_LIMIT_ONE     => 1;

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Infrastructure::Id->new; };
has schema     => undef;

sub map_identifier ( $self, $input ) {
    my $existing = $self->_existing_mapping($input);
    if ($existing) {
        return _skipped_mapping($existing);
    }

    return $self->_insert_or_reuse($input);
}

sub _insert_or_reuse ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_mapping($input); },
      );
    if ($created) {
        return $created;
    }

    return $self->_mapping_after_conflict( $input, $error );
}

sub _mapping_after_conflict ( $self, $input, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_mapping_after_unique( $input, $error );
}

sub _mapping_after_unique ( $self, $input, $error ) {
    if ( _mapping_id_conflict($error) ) {
        return $self->_mapping_after_id_conflict($input);
    }
    if ( _mapping_source_conflict($error) ) {
        return $self->_reuse_mapping_row( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _mapping_after_id_conflict ( $self, $input ) {
    my $existing = $self->_existing_mapping($input);
    if ($existing) {
        return _skipped_mapping($existing);
    }

    return $self->_retry_mapping_id($input);
}

sub _retry_mapping_id ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_mapping($input); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _reuse_mapping_row ( $self, $input, $error ) {
    my $existing = $self->_existing_mapping($input);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return _skipped_mapping($existing);
}

sub _mapping_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _mapping_source_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $SOURCE_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _create_mapping ( $self, $input ) {
    my $mapping = {
        canonical_url    => $input->{canonical_url},
        created_at       => $self->clock->now_iso8601,
        import_job_id    => $input->{import_job_id},
        legacy_id        => $input->{legacy_id},
        legacy_id_map_id => $self->id_service->uuid,
        legacy_type      => $input->{legacy_type},
        native_id        => $input->{native_id},
        native_type      => $input->{native_type},
        visibility       => $input->{visibility},
    };
    $self->schema->resultset('LegacyIdMap')->create($mapping);

    return $mapping;
}

sub find_native ( $self, $legacy_type, $legacy_id ) {
    return $self->schema->resultset('LegacyIdMap')->find(
        {
            legacy_id   => $legacy_id,
            legacy_type => $legacy_type,
        }
    );
}

sub _existing_mapping ( $self, $input ) {
    my $search = $self->schema->resultset('LegacyIdMap')->search_rs(
        {
            legacy_id   => $input->{legacy_id},
            legacy_type => $input->{legacy_type},
        },
        { rows => $ROW_LIMIT_ONE },
    );

    return _first_row($search);
}

sub _first_row ($search) {
    if ( $search && $search->can('single') ) {
        return $search->single;
    }

    my $undefined;
    return $undefined;
}

sub _skipped_mapping ($mapping) {
    return { %{ _mapping_hash($mapping) }, skipped => 1 };
}

sub _mapping_hash ($mapping) {
    return {
        canonical_url    => _column( $mapping, 'canonical_url' ),
        created_at       => _column( $mapping, 'created_at' ),
        import_job_id    => _column( $mapping, 'import_job_id' ),
        legacy_id        => _column( $mapping, 'legacy_id' ),
        legacy_id_map_id => _column( $mapping, 'legacy_id_map_id' ),
        legacy_type      => _column( $mapping, 'legacy_type' ),
        native_id        => _column( $mapping, 'native_id' ),
        native_type      => _column( $mapping, 'native_type' ),
        visibility       => _column( $mapping, 'visibility' ),
    };
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

1;
