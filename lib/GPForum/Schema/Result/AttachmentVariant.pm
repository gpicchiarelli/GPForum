package GPForum::Schema::Result::AttachmentVariant;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('attachment_variants');

__PACKAGE__->add_columns(
    attachment_variant_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    attachment_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    variant_type => {
        data_type   => 'text',
        is_nullable => 0,
    },
    object_key => {
        data_type   => 'text',
        is_nullable => 0,
    },
    media_type => {
        data_type   => 'text',
        is_nullable => 0,
    },
    byte_size => {
        data_type   => 'bigint',
        is_nullable => 0,
    },
    created_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('attachment_variant_id');
__PACKAGE__->add_unique_constraint(
    attachment_variants_variant_key => [ 'attachment_id', 'variant_type' ] );
__PACKAGE__->belongs_to(
    attachment => 'GPForum::Schema::Result::Attachment',
    'attachment_id'
);

1;

