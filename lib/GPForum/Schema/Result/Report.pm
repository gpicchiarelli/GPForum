package GPForum::Schema::Result::Report;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('reports');

__PACKAGE__->add_columns(
    report_id        => { data_type => 'uuid', is_nullable => 0 },
    reporter_user_id => { data_type => 'uuid', is_nullable => 0 },
    target_type      => { data_type => 'text', is_nullable => 0 },
    target_id        => { data_type => 'uuid', is_nullable => 0 },
    reason           => { data_type => 'text', is_nullable => 0 },
    details => { data_type => 'text', is_nullable => 0, default_value => q{} },
    status  =>
      { data_type => 'text', is_nullable => 0, default_value => 'open' },
    assigned_moderator_user_id => { data_type => 'uuid', is_nullable => 1 },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
    resolved_at =>
      { data_type => 'timestamp with time zone', is_nullable => 1 },
    resolution => { data_type => 'text', is_nullable => 1 },
);

__PACKAGE__->set_primary_key('report_id');
__PACKAGE__->belongs_to(
    reporter => 'GPForum::Schema::Result::User',
    'reporter_user_id'
);
__PACKAGE__->belongs_to(
    assigned_moderator => 'GPForum::Schema::Result::User',
    'assigned_moderator_user_id',
    { join_type => 'left' }
);

1;
