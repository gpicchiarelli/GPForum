package GPForum::Service::Portability::LegacyIdMapper;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $ID_CONSTRAINT     => 'legacy_id_map_pkey';
const my $SOURCE_CONSTRAINT => 'legacy_id_map_source_key';
const my $ROW_LIMIT_ONE     => 1;

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub map_identifier {
    my ( $self, $input ) = @_;

    my $existing = $self->_existing_mapping($input);
    if ($existing) {
        return _skipped_mapping($existing);
    }

    return $self->_insert_or_reuse($input);
}

sub _insert_or_reuse {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_create_mapping($input); };
    if ($created) {
        return $created;
    }

    return $self->_mapping_after_conflict( $input, $EVAL_ERROR );
}

sub _mapping_after_conflict {
    my ( $self, $input, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_mapping_after_unique( $input, $error );
}

sub _mapping_after_unique {
    my ( $self, $input, $error ) = @_;

    if ( _mapping_id_conflict($error) ) {
        return $self->_mapping_after_id_conflict($input);
    }
    if ( _mapping_source_conflict($error) ) {
        return $self->_reuse_mapping_row( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _mapping_after_id_conflict {
    my ( $self, $input ) = @_;

    my $existing = $self->_existing_mapping($input);
    if ($existing) {
        return _skipped_mapping($existing);
    }

    return $self->_retry_mapping_id($input);
}

sub _retry_mapping_id {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_create_mapping($input); };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _reuse_mapping_row {
    my ( $self, $input, $error ) = @_;

    my $existing = $self->_existing_mapping($input);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return _skipped_mapping($existing);
}

sub _mapping_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _mapping_source_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $SOURCE_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _create_mapping {
    my ( $self, $input ) = @_;

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

sub find_native {
    my ( $self, $legacy_type, $legacy_id ) = @_;

    return $self->schema->resultset('LegacyIdMap')->find(
        {
            legacy_id   => $legacy_id,
            legacy_type => $legacy_type,
        }
    );
}

sub _existing_mapping {
    my ( $self, $input ) = @_;

    my $search = $self->schema->resultset('LegacyIdMap')->search(
        {
            legacy_id   => $input->{legacy_id},
            legacy_type => $input->{legacy_type},
        },
        { rows => $ROW_LIMIT_ONE },
    );

    return _first_row($search);
}

sub _first_row {
    my ($search) = @_;

    if ( $search && $search->can('single') ) {
        return $search->single;
    }

    return;
}

sub _skipped_mapping {
    my ($mapping) = @_;

    return { %{ _mapping_hash($mapping) }, skipped => 1 };
}

sub _mapping_hash {
    my ($mapping) = @_;

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

sub _column {
    my ( $row, $name ) = @_;

    if ( ref $row eq 'HASH' ) {
        return $row->{$name};
    }
    if ( $row && $row->can('get_column') ) {
        return $row->get_column($name);
    }

    return;
}

1;
