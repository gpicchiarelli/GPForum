package GPForum::Service::Portability::ImportJobStore;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $ID_CONSTRAINT             => 'import_jobs_pkey';
const my $FAILURE_ID_CONSTRAINT     => 'import_failures_pkey';
const my $FAILURE_SOURCE_CONSTRAINT => 'idx_import_failures_source_unique';
const my $ROW_LIMIT_ONE             => 1;

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;
has validator  => sub {
    require GPForum::Service::Portability::ImportManifestValidator;
    return GPForum::Service::Portability::ImportManifestValidator->new;
};

sub create_job {
    my ( $self, $input ) = @_;

    my $validation = $self->validator->validate( $input->{manifest} || {} );
    if ( !$validation->{ok} ) {
        return { ok => 0, errors => $validation->{errors} };
    }

    return $self->_insert_or_retry_job($input);
}

sub _insert_or_retry_job {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_create_job($input); };
    if ($created) {
        return _created_job($created);
    }

    return $self->_job_after_conflict( $input, $EVAL_ERROR );
}

sub _job_after_conflict {
    my ( $self, $input, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( !_job_id_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_retry_job_id($input);
}

sub _retry_job_id {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_create_job($input); };
    if ($created) {
        return _created_job($created);
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _job_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _create_job {
    my ( $self, $input ) = @_;

    my $job = $self->_job_row($input);
    $self->schema->resultset('ImportJob')->create($job);

    return $job;
}

sub _job_row {
    my ( $self, $input ) = @_;

    return {
        adapter_name  => $input->{manifest}{adapter_name},
        created_at    => $self->clock->now_iso8601,
        created_by    => $input->{actor_user_id},
        dry_run       => $input->{manifest}{dry_run} ? 1 : 0,
        finished_at   => undef,
        import_job_id => $self->id_service->uuid,
        manifest      => $input->{manifest},
        progress      => {},
        source_system => $input->{manifest}{source_system},
        started_at    => undef,
        status        => 'pending',
    };
}

sub _created_job {
    my ($job) = @_;

    return { ok => 1, job => $job };
}

sub record_failure {
    my ( $self, $input ) = @_;

    my $existing = $self->_existing_failure($input);
    if ($existing) {
        return _skipped_failure($existing);
    }

    return $self->_insert_or_reuse_failure($input);
}

sub _insert_or_reuse_failure {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_create_failure($input); };
    if ($created) {
        return $created;
    }

    return $self->_failure_after_conflict( $input, $EVAL_ERROR );
}

sub _failure_after_conflict {
    my ( $self, $input, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_failure_after_unique( $input, $error );
}

sub _failure_after_unique {
    my ( $self, $input, $error ) = @_;

    if ( _failure_id_conflict($error) ) {
        return $self->_failure_after_id_conflict($input);
    }
    if ( _failure_source_conflict($error) ) {
        return $self->_reuse_failure_row( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _failure_after_id_conflict {
    my ( $self, $input ) = @_;

    my $existing = $self->_existing_failure($input);
    if ($existing) {
        return _skipped_failure($existing);
    }

    return $self->_retry_failure_id($input);
}

sub _retry_failure_id {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_create_failure($input); };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _reuse_failure_row {
    my ( $self, $input, $error ) = @_;

    my $existing = $self->_existing_failure($input);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return _skipped_failure($existing);
}

sub _failure_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $FAILURE_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _failure_source_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $FAILURE_SOURCE_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _create_failure {
    my ( $self, $input ) = @_;

    my $failure = {
        created_at         => $self->clock->now_iso8601,
        error_code         => $input->{error_code},
        error_message      => $input->{error_message},
        import_failure_id  => $self->id_service->uuid,
        import_job_id      => $input->{import_job_id},
        payload            => $input->{payload} || {},
        source_record_id   => $input->{source_record_id},
        source_record_type => $input->{source_record_type},
    };
    $self->schema->resultset('ImportFailure')->create($failure);

    return $failure;
}

sub _existing_failure {
    my ( $self, $input ) = @_;

    my $search = $self->schema->resultset('ImportFailure')->search(
        {
            import_job_id      => $input->{import_job_id},
            source_record_id   => $input->{source_record_id},
            source_record_type => $input->{source_record_type},
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

sub _skipped_failure {
    my ($failure) = @_;

    return { %{ _failure_hash($failure) }, skipped => 1 };
}

sub _failure_hash {
    my ($failure) = @_;

    return {
        created_at         => _column( $failure, 'created_at' ),
        error_code         => _column( $failure, 'error_code' ),
        error_message      => _column( $failure, 'error_message' ),
        import_failure_id  => _column( $failure, 'import_failure_id' ),
        import_job_id      => _column( $failure, 'import_job_id' ),
        payload            => _column( $failure, 'payload' ),
        source_record_id   => _column( $failure, 'source_record_id' ),
        source_record_type => _column( $failure, 'source_record_type' ),
    };
}

sub update_progress {
    my ( $self, $import_job_id, $progress ) = @_;

    my $job = $self->schema->resultset('ImportJob')->find($import_job_id);
    if ( _same_progress( _column( $job, 'progress' ), $progress ) ) {
        return {
            import_job_id => $import_job_id,
            progress      => $progress,
            skipped       => 1,
        };
    }

    $job->update( { progress => $progress } );

    return { import_job_id => $import_job_id, progress => $progress };
}

sub _same_progress {
    my ( $held, $incoming ) = @_;

    if ( !_hash($held) ) {
        return 0;
    }
    if ( !_hash($incoming) ) {
        return 0;
    }

    return _same_pairs( $held, $incoming );
}

sub _hash {
    my ($value) = @_;

    if ( ref $value eq 'HASH' ) {
        return 1;
    }

    return 0;
}

sub _same_pairs {
    my ( $held, $incoming ) = @_;

    if ( !_same_keys( $held, $incoming ) ) {
        return 0;
    }

    return _same_values( $held, $incoming );
}

sub _same_keys {
    my ( $held, $incoming ) = @_;

    if ( ( scalar keys %{$held} ) != ( scalar keys %{$incoming} ) ) {
        return 0;
    }

    return _incoming_has_keys( $held, $incoming );
}

sub _incoming_has_keys {
    my ( $held, $incoming ) = @_;

    for my $key ( keys %{$held} ) {
        if ( !exists $incoming->{$key} ) {
            return 0;
        }
    }

    return 1;
}

sub _same_values {
    my ( $held, $incoming ) = @_;

    for my $key ( keys %{$held} ) {
        if ( !_same_value( $held->{$key}, $incoming->{$key} ) ) {
            return 0;
        }
    }

    return 1;
}

sub _same_value {
    my ( $held, $incoming ) = @_;

    if ( _text($held) ne _text($incoming) ) {
        return 0;
    }

    return 1;
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

sub _text {
    my ($value) = @_;

    if ( defined $value ) {
        return $value;
    }

    return q{};
}

1;
