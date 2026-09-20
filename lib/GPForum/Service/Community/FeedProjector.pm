package GPForum::Service::Community::FeedProjector;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;

our $VERSION = '0.001';

const my $DEFAULT_RANK               => 0;
const my $DEFAULT_VISIBILITY_VERSION => 1;
const my $DEFAULT_PERMISSION_VERSION => 1;
const my $POST_ITEM                  => 'post';
const my $THREAD_ITEM                => 'thread';
const my @ITEM_COPY => qw(
  created_at
  permission_version
  rank_score
  visibility_version
);

has schema => undef;

sub project_item {
    my ( $self, $input ) = @_;

    my @users = _unique_users( $input->{user_ids} || [] );
    my @items = map { $self->_project_user( $_, $input ) } @users;

    return { ok => 1, projected => scalar @items, items => \@items };
}

sub _project_user {
    my ( $self, $user_id, $input ) = @_;

    my $item     = _item_for_user( $user_id, $input );
    my $existing = $self->_existing_item($item);
    if ( _unchanged_item( $existing, $item ) ) {
        return { %{$item}, skipped => 1 };
    }
    if ($existing) {
        return $self->_persist_item($item);
    }

    return $self->_insert_or_reuse_item($item);
}

sub _insert_or_reuse_item {
    my ( $self, $item ) = @_;

    my $created = eval { return $self->_insert_item($item); };
    if ($created) {
        return $created;
    }

    return $self->_item_after_conflict( $item, $EVAL_ERROR );
}

sub _item_after_conflict {
    my ( $self, $item, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    my $existing = $self->_existing_item($item);
    if ( !_unchanged_item( $existing, $item ) ) {
        return $self->_write_after_conflict( $existing, $item, $error );
    }

    return { %{$item}, skipped => 1 };
}

sub _write_after_conflict {
    my ( $self, $existing, $item, $error ) = @_;

    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_persist_item($item);
}

sub _insert_item {
    my ( $self, $item ) = @_;

    $self->_feed_resultset->create($item);

    return $item;
}

sub _persist_item {
    my ( $self, $item ) = @_;

    $self->_feed_resultset->update_or_create($item);

    return $item;
}

sub _existing_item {
    my ( $self, $item ) = @_;

    return $self->_feed_resultset->find(
        {
            item_id   => $item->{item_id},
            item_type => $item->{item_type},
            user_id   => $item->{user_id},
        }
    );
}

sub _unchanged_item {
    my ( $stored, $candidate ) = @_;

    if ( !$stored ) {
        return 0;
    }

    return _same_item( $stored, $candidate );
}

sub _same_item {
    my ( $stored, $candidate ) = @_;

    for my $name (@ITEM_COPY) {
        if ( !_same_text( _column( $stored, $name ), $candidate->{$name} ) ) {
            return 0;
        }
    }

    return 1;
}

sub _same_text {
    my ( $stored, $candidate ) = @_;

    $stored    = defined $stored    ? $stored    : q{};
    $candidate = defined $candidate ? $candidate : q{};

    return $stored eq $candidate ? 1 : 0;
}

sub _column {
    my ( $row, $name ) = @_;

    if ( ref $row eq 'HASH' ) {
        return $row->{$name};
    }
    if ( $row && $row->can('get_column') ) {
        return $row->get_column($name);
    }

    return;
}

sub remove_item {
    my ( $self, $input ) = @_;

    if ( !_item_key($input) ) {
        return { ok => 1, removed => 0 };
    }

    my $deleted = $self->_delete_items( _item_query($input) );

    return { ok => 1, removed => $deleted || 0 };
}

sub remove_thread {
    my ( $self, $thread_id ) = @_;

    my $thread_removed = $self->remove_item(
        {
            item_id   => $thread_id,
            item_type => $THREAD_ITEM,
        }
    );

    return $self->_with_post_removals( $thread_id, $thread_removed );
}

sub _with_post_removals {
    my ( $self, $thread_id, $thread_removed ) = @_;

    my $posts_removed = $self->_remove_thread_posts($thread_id);
    my $thread_count  = $thread_removed->{removed} || 0;

    return {
        ok            => 1,
        posts_removed => $posts_removed,
        removed       => $thread_count + $posts_removed,
    };
}

sub _remove_thread_posts {
    my ( $self, $thread_id ) = @_;

    my $removed = 0;
    for my $post_id ( $self->_post_ids_for_thread($thread_id) ) {
        my $result = $self->remove_item(
            {
                item_id   => $post_id,
                item_type => $POST_ITEM,
            }
        );
        $removed += $result->{removed} || 0;
    }

    return $removed;
}

sub _post_ids_for_thread {
    my ( $self, $thread_id ) = @_;

    my $posts = $self->_post_resultset;
    if ( !$posts ) {
        return;
    }

    return
      map { _post_id($_) }
      _search_rows( $posts->search( { thread_id => $thread_id } ) );
}

sub _post_id {
    my ($row) = @_;

    return if !$row;

    return $row->get_column('post_id');
}

sub _search_rows {
    my ($search) = @_;

    return if !$search;
    if ( $search->can('all') ) {
        return $search->all;
    }
    if ( $search->can('rows') ) {
        return @{ $search->rows };
    }

    return;
}

sub _delete_items {
    my ( $self, $query ) = @_;

    my $items = $self->_feed_resultset;
    if ( !$items ) {
        return 0;
    }

    my $deleted = $items->search($query)->delete;

    return $deleted || 0;
}

sub _feed_resultset {
    my ($self) = @_;

    return $self->schema->resultset('UserFeedItem');
}

sub _post_resultset {
    my ($self) = @_;

    my $schema = $self->schema;
    if ( !$schema ) {
        return;
    }

    return $schema->resultset('Post');
}

sub _item_key {
    my ($input) = @_;

    return defined $input->{item_type}
      && defined $input->{item_id} ? 1 : 0;
}

sub _item_query {
    my ($input) = @_;

    return {
        item_id   => $input->{item_id},
        item_type => $input->{item_type},
    };
}

sub _item_for_user {
    my ( $user_id, $input ) = @_;

    return {
        user_id            => $user_id,
        item_type          => $input->{item_type},
        item_id            => $input->{item_id},
        created_at         => $input->{created_at},
        rank_score         => $input->{rank_score} || $DEFAULT_RANK,
        visibility_version => $input->{visibility_version}
          || $DEFAULT_VISIBILITY_VERSION,
        permission_version => $input->{permission_version}
          || $DEFAULT_PERMISSION_VERSION,
    };
}

sub _unique_users {
    my ($users) = @_;

    my %seen;

    return grep { defined && !$seen{$_}++ } @{$users};
}

1;
