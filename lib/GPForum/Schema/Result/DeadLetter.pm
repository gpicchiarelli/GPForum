package GPForum::Schema::Result::DeadLetter;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

use GPForum::Schema::JsonColumn;

our $VERSION = '0.001';

__PACKAGE__->table('dead_letters');

__PACKAGE__->add_columns(
    dead_letter_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    source_table => {
        data_type   => 'text',
        is_nullable => 0,
    },
    source_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    payload => {
        data_type     => 'jsonb',
        default_value => '{}',
        is_nullable   => 0,
    },
    error_class => {
        data_type   => 'text',
        is_nullable => 0,
    },
    error_message => {
        data_type   => 'text',
        is_nullable => 0,
    },
    failure_type => {
        data_type     => 'text',
        default_value => 'transient',
        is_nullable   => 0,
    },
    retry_count => {
        data_type     => 'integer',
        default_value => 0,
        is_nullable   => 0,
    },
    first_failed_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    last_failed_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
);

GPForum::Schema::JsonColumn->inflate_json_columns(__PACKAGE__);

__PACKAGE__->set_primary_key('dead_letter_id');

1;
