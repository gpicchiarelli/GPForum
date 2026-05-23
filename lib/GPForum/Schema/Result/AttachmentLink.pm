package GPForum::Schema::Result::AttachmentLink;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('attachment_links');

__PACKAGE__->add_columns(
    attachment_link_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    attachment_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    target_type => {
        data_type   => 'text',
        is_nullable => 0,
    },
    target_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    created_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('attachment_link_id');
__PACKAGE__->add_unique_constraint( attachment_links_target_key =>
      [ 'attachment_id', 'target_type', 'target_id' ] );
__PACKAGE__->belongs_to(
    attachment => 'GPForum::Schema::Result::Attachment',
    'attachment_id'
);

1;

