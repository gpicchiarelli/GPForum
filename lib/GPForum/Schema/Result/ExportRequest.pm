package GPForum::Schema::Result::ExportRequest;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

use GPForum::Schema::JsonColumn;

our $VERSION = '0.001';

__PACKAGE__->table('export_requests');

__PACKAGE__->add_columns(
    export_request_id => { data_type => 'uuid', is_nullable => 0 },
    requester_user_id => { data_type => 'uuid', is_nullable => 0 },
    subject_user_id   => { data_type => 'uuid', is_nullable => 0 },
    export_type       => { data_type => 'text', is_nullable => 0 },
    format            => { data_type => 'text', is_nullable => 0 },
    status            => { data_type => 'text', is_nullable => 0 },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
    finished_at =>
      { data_type => 'timestamp with time zone', is_nullable => 1 },
    manifest =>
      { data_type => 'jsonb', is_nullable => 0, default_value => '{}' },
);

GPForum::Schema::JsonColumn->inflate_json_columns(__PACKAGE__);

__PACKAGE__->set_primary_key('export_request_id');
__PACKAGE__->belongs_to(
    requester => 'GPForum::Schema::Result::User',
    'requester_user_id'
);
__PACKAGE__->belongs_to(
    subject => 'GPForum::Schema::Result::User',
    'subject_user_id'
);

1;
