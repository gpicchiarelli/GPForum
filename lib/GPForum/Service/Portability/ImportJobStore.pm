# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Portability::ImportJobStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Infrastructure::Id;

our $VERSION = '0.001';

const my $ID_CONSTRAINT             => 'import_jobs_pkey';
const my $FAILURE_ID_CONSTRAINT     => 'import_failures_pkey';
const my $FAILURE_SOURCE_CONSTRAINT => 'idx_import_failures_source_unique';
const my $ROW_LIMIT_ONE             => 1;

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Infrastructure::Id->new; };
has schema     => undef;
has validator  => sub {
    require GPForum::Service::Portability::ImportManifestValidator;
    return GPForum::Service::Portability::ImportManifestValidator->new;
};

sub create_job ( $self, $input ) {
    my $validation = $self->validator->validate( $input->{manifest} || {} );
    if ( !$validation->{ok} ) {
        return { ok => 0, errors => $validation->{errors} };
    }

    return $self->schema->txn_do(
        sub {
            return $self->_insert_or_retry_job($input);
        }
    );
}

sub _insert_or_retry_job ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_job($input); },
      );
    if ($created) {
        return _created_job($created);
    }

    return $self->_job_after_conflict( $input, $error );
}

sub _job_after_conflict ( $self, $input, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( !_job_id_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_retry_job_id($input);
}

sub _retry_job_id ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_job($input); },
      );
    if ($created) {
        return _created_job($created);
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _job_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _create_job ( $self, $input ) {
    my $job = $self->_job_row($input);
    $self->schema->resultset('ImportJob')->create($job);

    return $job;
}

sub _job_row ( $self, $input ) {
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

sub _created_job ($job) {
    return { ok => 1, job => $job };
}

sub record_failure ( $self, $input ) {
    return $self->schema->txn_do(
        sub {
            return $self->_record_failure($input);
        }
    );
}

# The existence probe and the insert are one decision: outside a transaction
# a concurrent writer could slip a row in between them.
sub _record_failure ( $self, $input ) {
    my $existing = $self->_existing_failure($input);
    if ($existing) {
        return _skipped_failure($existing);
    }

    return $self->_insert_or_reuse_failure($input);
}

sub _insert_or_reuse_failure ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_failure($input); },
      );
    if ($created) {
        return $created;
    }

    return $self->_failure_after_conflict( $input, $error );
}

sub _failure_after_conflict ( $self, $input, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_failure_after_unique( $input, $error );
}

sub _failure_after_unique ( $self, $input, $error ) {
    if ( _failure_id_conflict($error) ) {
        return $self->_failure_after_id_conflict($input);
    }
    if ( _failure_source_conflict($error) ) {
        return $self->_reuse_failure_row( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _failure_after_id_conflict ( $self, $input ) {
    my $existing = $self->_existing_failure($input);
    if ($existing) {
        return _skipped_failure($existing);
    }

    return $self->_retry_failure_id($input);
}

sub _retry_failure_id ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_failure($input); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _reuse_failure_row ( $self, $input, $error ) {
    my $existing = $self->_existing_failure($input);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return _skipped_failure($existing);
}

sub _failure_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $FAILURE_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _failure_source_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $FAILURE_SOURCE_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _create_failure ( $self, $input ) {
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

sub _existing_failure ( $self, $input ) {
    my $search = $self->schema->resultset('ImportFailure')->search_rs(
        {
            import_job_id      => $input->{import_job_id},
            source_record_id   => $input->{source_record_id},
            source_record_type => $input->{source_record_type},
        },
        { rows => $ROW_LIMIT_ONE },
    );

    return _first_row($search);
}

sub _first_row ($search) {
    if ( $search && $search->can('single') ) {
        return $search->single;
    }

    return;
}

sub _skipped_failure ($failure) {
    return { %{ _failure_hash($failure) }, skipped => 1 };
}

sub _failure_hash ($failure) {
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

sub update_progress ( $self, $import_job_id, $progress ) {
    return $self->schema->txn_do(
        sub {
            return $self->_update_progress( $import_job_id, $progress );
        }
    );
}

sub _update_progress ( $self, $import_job_id, $progress ) {
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

sub _same_progress ( $held, $incoming ) {
    if ( !_hash($held) ) {
        return 0;
    }
    if ( !_hash($incoming) ) {
        return 0;
    }

    return _same_pairs( $held, $incoming );
}

sub _hash ($value) {
    if ( ref $value eq 'HASH' ) {
        return 1;
    }

    return 0;
}

sub _same_pairs ( $held, $incoming ) {
    if ( !_same_keys( $held, $incoming ) ) {
        return 0;
    }

    return _same_values( $held, $incoming );
}

sub _same_keys ( $held, $incoming ) {
    if ( ( scalar keys %{$held} ) != ( scalar keys %{$incoming} ) ) {
        return 0;
    }

    return _incoming_has_keys( $held, $incoming );
}

sub _incoming_has_keys ( $held, $incoming ) {
    for my $key ( keys %{$held} ) {
        if ( !exists $incoming->{$key} ) {
            return 0;
        }
    }

    return 1;
}

sub _same_values ( $held, $incoming ) {
    for my $key ( keys %{$held} ) {
        if ( !_same_value( $held->{$key}, $incoming->{$key} ) ) {
            return 0;
        }
    }

    return 1;
}

sub _same_value ( $held, $incoming ) {
    if ( _text($held) ne _text($incoming) ) {
        return 0;
    }

    return 1;
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

sub _text ($value) {
    if ( defined $value ) {
        return $value;
    }

    return q{};
}

1;

__END__

=head1 NAME

GPForum::Service::Portability::ImportJobStore - Create import jobs and record their failures and progress.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $imports = GPForum::Service::Portability::ImportJobStore->new(
        schema => $schema,
    );
    my $created = $imports->create_job(
        {
            actor_user_id => $admin_id,
            manifest      => {
                adapter_name   => 'legacy_forum_v1',
                dry_run        => 1,
                records        => {
                    categories => 4,
                    posts      => 900,
                    threads    => 120,
                    users      => 80,
                },
                source_system  => 'legacy-forum',
                source_version => '1.4',
            },
        }
    );
    my $job_id = $created->{job}{import_job_id};

    $imports->record_failure(
        {
            error_code         => 'missing_author',
            error_message      => 'author 17 was not imported',
            import_job_id      => $job_id,
            payload            => { post_id => 4211 },
            source_record_id   => '4211',
            source_record_type => 'post',
        }
    );
    $imports->update_progress( $job_id, { posts => 450 } );

=head1 DESCRIPTION

The bookkeeping of an import from another forum. A job is created only from
a manifest that L<GPForum::Service::Portability::ImportManifestValidator>
accepts, and starts as C<pending>. While the import runs, each source record
that cannot be imported is recorded once as an import failure, and the job's
progress is replaced as it advances.

Every write can be repeated. A failure is identified by its job, source
record type and source record id, which a unique index backs, so a retried
batch does not record it twice; the lookup and the insert share one
transaction. Writing the progress the job already holds changes nothing.
Inserts run under savepoints through
L<GPForum::Infrastructure::UniqueConflict>, and a conflict on a generated id
is retried once with a fresh id.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor. C<schema> is required; C<clock>, C<id_service> and
C<validator> default to L<GPForum::Service::Clock>,
L<GPForum::Infrastructure::Id> and
L<GPForum::Service::Portability::ImportManifestValidator>.

=head2 create_job

Takes a hash reference with C<manifest> and C<actor_user_id>. When the
manifest is invalid, returns C<< { ok => 0, errors => \%errors } >> with the
validator's errors and writes nothing. Otherwise inserts the job in a
transaction and returns C<< { ok => 1, job => \%job } >>, where the job has
C<import_job_id>, C<adapter_name>, C<source_system>, C<dry_run> (0 or 1),
C<manifest>, C<< status => 'pending' >>, an empty C<progress>,
C<created_by>, C<created_at>, and undefined C<started_at> and
C<finished_at>.

=head2 record_failure

Takes a hash reference with C<import_job_id>, C<source_record_type>,
C<source_record_id>, C<error_code>, C<error_message> and an optional
C<payload> (an empty hash when absent). In a transaction, inserts the
failure and returns its hash (with C<import_failure_id> and C<created_at>
added), or, when that source record already has a failure in the job,
returns the existing failure's hash with C<< skipped => 1 >>.

=head2 update_progress

Takes a job id and a progress hash reference. In a transaction, replaces
the job's progress and returns C<< { import_job_id, progress } >>. When the
stored progress has the same keys and the same values (compared as strings,
one level deep), writes nothing and adds C<< skipped => 1 >>.

=head1 DIAGNOSTICS

An invalid manifest is returned as errors, not thrown. Database errors other
than the handled unique conflicts are rethrown and the transaction rolls
back. C<update_progress> dies when the job id matches no job.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Portability::ImportManifestValidator>,
L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::Infrastructure::Row>,
L<GPForum::Infrastructure::Id>, L<GPForum::Service::Clock>.

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
