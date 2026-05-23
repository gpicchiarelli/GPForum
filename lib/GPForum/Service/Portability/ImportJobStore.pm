package GPForum::Service::Portability::ImportJobStore;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

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
    return { ok => 0, errors => $validation->{errors} } if !$validation->{ok};

    my $job = {
        import_job_id => $self->id_service->uuid,
        source_system => $input->{manifest}{source_system},
        adapter_name  => $input->{manifest}{adapter_name},
        status        => 'pending',
        dry_run       => $input->{manifest}{dry_run} ? 1 : 0,
        manifest      => $input->{manifest},
        progress      => {},
        created_by    => $input->{actor_user_id},
        created_at    => $self->clock->now_iso8601,
        started_at    => undef,
        finished_at   => undef,
    };
    $self->schema->resultset('ImportJob')->create($job);

    return { ok => 1, job => $job };
}

sub record_failure {
    my ( $self, $input ) = @_;

    my $failure = {
        import_failure_id  => $self->id_service->uuid,
        import_job_id      => $input->{import_job_id},
        source_record_type => $input->{source_record_type},
        source_record_id   => $input->{source_record_id},
        error_code         => $input->{error_code},
        error_message      => $input->{error_message},
        payload            => $input->{payload} || {},
        created_at         => $self->clock->now_iso8601,
    };
    $self->schema->resultset('ImportFailure')->create($failure);

    return $failure;
}

sub update_progress {
    my ( $self, $import_job_id, $progress ) = @_;

    my $job = $self->schema->resultset('ImportJob')->find($import_job_id);
    $job->update( { progress => $progress } );

    return { import_job_id => $import_job_id, progress => $progress };
}

1;
