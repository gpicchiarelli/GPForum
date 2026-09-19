package GPForum::Schema::Result::SearchDocument;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('search_documents');

__PACKAGE__->add_columns(
    search_document_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    entity_type => {
        data_type   => 'text',
        is_nullable => 0,
    },
    entity_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    category_id => {
        data_type   => 'uuid',
        is_nullable => 1,
    },
    author_user_id => {
        data_type   => 'uuid',
        is_nullable => 1,
    },
    space_id => {
        data_type   => 'uuid',
        is_nullable => 1,
    },
    visibility => {
        data_type   => 'text',
        is_nullable => 0,
    },
    permission_scope => {
        data_type   => 'text',
        is_nullable => 0,
    },
    visibility_version => {
        data_type   => 'bigint',
        is_nullable => 0,
    },
    permission_version => {
        data_type   => 'bigint',
        is_nullable => 0,
    },
    language => {
        data_type     => 'text',
        default_value => 'simple',
        is_nullable   => 0,
    },
    title => {
        data_type   => 'text',
        is_nullable => 0,
    },
    title_normalized => {
        data_type    => 'text',
        is_nullable  => 0,
        is_generated => 1,
    },
    body => {
        data_type   => 'text',
        is_nullable => 0,
    },
    search_vector => {
        data_type   => 'tsvector',
        is_nullable => 0,
    },
    source_version => {
        data_type   => 'bigint',
        is_nullable => 0,
    },
    source_created_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
    indexed_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('search_document_id');
__PACKAGE__->add_unique_constraint(
    search_documents_entity_key => [ 'entity_type', 'entity_id' ] );
__PACKAGE__->belongs_to(
    author => 'GPForum::Schema::Result::User',
    'author_user_id',
    { join_type => 'left' }
);

1;
