# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::ViewModel::Forum::Form;
use GPForum::ViewModel::Forum::Page;
use GPForum::ViewModel::Forum::Presenter;
use GPForum::ViewModel::Forum::Rows;
use Test::More;

our $VERSION = '0.001';

my $rows = GPForum::ViewModel::Forum::Rows->new;
my $post = $rows->post(
    {
        author_username => 'giacomo',
        body            => '<p>Direct</p>',
        post_id         => 'post-1',
        thread_id       => 'thread-1',
        visibility      => 'public',
    }
);
is( $post->{body}, '<p>Direct</p>',
    'rows prefer a direct post body when present' );
is( $post->{ui}{permalink},
    'post-post-1', 'rows prepare post permalink metadata' );
ok( $rows->has_text('thread-1'), 'rows treat identifiers as text' );
ok( !$rows->has_text(q{}),       'rows reject empty strings' );

my $forms      = GPForum::ViewModel::Forum::Form->new;
my $from_input = $forms->new_thread_form(
    selected_category_id => 'category-9',
    values               => {
        category_id => 'category-1',
        visibility  => q{},
    },
);
is( $from_input->{selected_category_id},
    'category-9', 'form prefers selected_category_id over values' );
my ($input_visibility) =
  grep { $_->{name} eq 'visibility' } @{ $from_input->{form_fields} };
is( $input_visibility->{value},
    q{},
    'form leaves an empty visibility empty: inherit the category (ADR 0102)' );

my $pages       = GPForum::ViewModel::Forum::Page->new;
my $thread_page = $pages->thread_page(
    attachments_by_post => { 'post-1' => [ { attachment_id => 'att-1' } ] },
    attachment_delete_command_ids => { 'att-1'  => 'att-delete-1' },
    attachment_upload_command_ids => { 'post-1' => 'att-upload-1' },
    edit_command_ids              => { 'post-1' => 'edit-1' },
    page                          => {
        posts  => { items     => [ { post_id => 'post-1', body => 'Hi' } ], },
        thread => { thread_id => 'thread-1', title => 'Welcome' },
    },
    reply_command_id => 'reply-1',
);
is( $thread_page->{reply_command_id},
    'reply-1', 'page keeps the reply command id' );
is( $thread_page->{posts}[0]{attachments}[0]{attachment_id},
    'att-1', 'page attaches files by post id' );
is( $thread_page->{posts}[0]{attachments}[0]{delete_command_id},
    'att-delete-1', 'page keeps attachment delete command ids' );
ok( !$thread_page->{posts}[0]{upload_command_id},
    'page omits upload command ids unless the post is editable' );
is( $thread_page->{thread}{ui}{heading_id},
    'thread-thread-1-heading', 'page shapes thread heading metadata' );

my $presenter = GPForum::ViewModel::Forum::Presenter->new;
is( $presenter->category( { category_id => 'category-1' } )->{category_id},
    'category-1', 'presenter facade still exposes row helpers' );
my $presented_form =
  $presenter->new_thread_form( values => { visibility => 'members' } );
my ($presented_visibility) =
  grep { $_->{name} eq 'visibility' } @{ $presented_form->{form_fields} };
is( $presented_visibility->{value},
    'members', 'presenter facade still builds the new-thread form' );

done_testing();

1;
