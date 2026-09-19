package GPForum::Schema::Result::ErasureJob;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('erasure_jobs');

__PACKAGE__->add_columns(
    erasure_job_id      => { data_type => 'uuid', is_nullable => 0 },
    deletion_request_id => { data_type => 'uuid', is_nullable => 0 },
    status              => { data_type => 'text', is_nullable => 0 },
    scheduled_at        =>
      { data_type => 'timestamp with time zone', is_nullable => 0 },
    completed_at =>
      { data_type => 'timestamp with time zone', is_nullable => 1 },
    last_error => { data_type => 'text', is_nullable => 1 },
);

__PACKAGE__->set_primary_key('erasure_job_id');
__PACKAGE__->add_unique_constraint(
    erasure_jobs_request_key => ['deletion_request_id'] );
__PACKAGE__->belongs_to(
    deletion_request => 'GPForum::Schema::Result::DeletionRequest',
    'deletion_request_id'
);

1;
