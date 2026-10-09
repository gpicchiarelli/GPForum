# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Portability::ImportJobStore;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::X::Conflict;
use GPForum::Service::Clock;
use GPForum::Infrastructure::Id;

our $VERSION = '0.001';

const my $ID_CONSTRAINT             => 'import_jobs_pkey';
const my $FAILURE_ID_CONSTRAINT     => 'import_failures_pkey';
const my $FAILURE_SOURCE_CONSTRAINT => 'idx_import_failures_source_unique';
const my $ROW_LIMIT_ONE             => 1;
const my @FAILURE_COLUMNS => qw(
  created_at
  error_code
  error_message
  import_failure_id
  import_job_id
  payload
  source_record_id
  source_record_type
);

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Infrastructure::Id->new; };
__PACKAGE__->requires(qw(schema));
has validator => sub {
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
            return { ok => 1, job => $self->_insert_job($input) };
        }
    );
}

# A job id that collides is drawn again, once.
sub _insert_job ( $self, $input ) {
    my ( $job, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_job($input); } );
    return $job if $job;

    my $conflict = GPForum::X::Conflict->caught($error);
    if ( !$conflict || !$conflict->on($ID_CONSTRAINT) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    ( $job, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_job($input); } );
    return $job if $job;

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

sub _create_job ( $self, $input ) {
    my $job = {
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
    $self->schema->resultset('ImportJob')->create($job);

    return $job;
}

# The existence probe and the insert are one decision: outside a transaction
# a concurrent writer could slip a row in between them. A failure id that
# collides is drawn again, once; a failure a concurrent writer recorded first
# for the same source record is answered with its row.
sub record_failure ( $self, $input ) {
    return $self->schema->txn_do(
        sub {
            return $self->_record_failure($input);
        }
    );
}

sub _record_failure ( $self, $input ) {
    my $existing = $self->_existing_failure($input);
    return _skipped_failure($existing) if $existing;

    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_failure($input); } );
    return $created if $created;

    my $conflict = GPForum::X::Conflict->caught($error);
    if (
        !$conflict
        || !(
               $conflict->on($FAILURE_ID_CONSTRAINT)
            || $conflict->on($FAILURE_SOURCE_CONSTRAINT)
        )
      )
    {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    $existing = $self->_existing_failure($input);
    return _skipped_failure($existing) if $existing;
    if ( $conflict->on($FAILURE_SOURCE_CONSTRAINT) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_failure($input); } );
    return $created if $created;

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
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

    return $search && $search->can('single') ? $search->single : undef;
}

sub _skipped_failure ($failure) {
    return {
        ( map { $_ => _column( $failure, $_ ) } @FAILURE_COLUMNS ),
        skipped => 1,
    };
}

sub update_progress ( $self, $import_job_id, $progress ) {
    return $self->schema->txn_do(
        sub {
            my $job =
              $self->schema->resultset('ImportJob')->find($import_job_id);
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
    );
}

# Two progress hashes are the same when they have the same keys and each
# value reads the same, undef as the empty string.
sub _same_progress ( $held, $incoming ) {
    return 0 if ref $held ne 'HASH' || ref $incoming ne 'HASH';
    return 0 if scalar keys %{$held} != scalar keys %{$incoming};

    for my $key ( keys %{$held} ) {
        return 0 if !exists $incoming->{$key};
        return 0 if ( $held->{$key} // q{} ) ne ( $incoming->{$key} // q{} );
    }

    return 1;
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
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
