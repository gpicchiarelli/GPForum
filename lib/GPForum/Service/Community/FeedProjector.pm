# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Community::FeedProjector;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

our $VERSION = '0.001';

const my $DEFAULT_RANK               => 0;
const my $DEFAULT_VISIBILITY_VERSION => 1;
const my $DEFAULT_PERMISSION_VERSION => 1;
const my $POST_ITEM                  => 'post';
const my $THREAD_ITEM                => 'thread';
const my $UPSERT_SQL => join q{ },
  q{INSERT INTO user_feed_items (user_id, item_type, item_id, created_at,},
  q{rank_score, visibility_version, permission_version)},
  q{SELECT recipient, ?, ?, ?, ?, ?, ? FROM unnest(?::uuid[]) AS recipient},
  q{ON CONFLICT (user_id, item_type, item_id) DO UPDATE SET},
  q{created_at = EXCLUDED.created_at, rank_score = EXCLUDED.rank_score,},
  q{visibility_version = EXCLUDED.visibility_version,},
  q{permission_version = EXCLUDED.permission_version},
  q{WHERE (user_feed_items.created_at, user_feed_items.rank_score,},
  q{user_feed_items.visibility_version, user_feed_items.permission_version)},
  q{IS DISTINCT FROM (EXCLUDED.created_at, EXCLUDED.rank_score,},
  q{EXCLUDED.visibility_version, EXCLUDED.permission_version)};

__PACKAGE__->requires(qw(schema));

sub project_item ( $self, $input ) {
    return $self->schema->txn_do(
        sub {
            return $self->_project_item($input);
        }
    );
}

# Every recipient in one statement: the ids travel as one array, whatever
# their number, and PostgreSQL inserts or refreshes each row in place. It
# used to read and write each recipient in turn -- two statements per
# subscriber of a popular thread, in one ever longer transaction (8.7).
# Rows that already hold this item unchanged are left alone.
sub _project_item ( $self, $input ) {
    my @users = _unique_users( $input->{user_ids} || [] );
    return { ok => 1, projected => 0, written => 0 } if !@users;

    my $written = $self->schema->storage->dbh_do(
        sub ( $, $dbh ) {
            return $dbh->do(
                $UPSERT_SQL,
                undef,
                $input->{item_type},
                $input->{item_id},
                $input->{created_at},
                $input->{rank_score}         || $DEFAULT_RANK,
                $input->{visibility_version} || $DEFAULT_VISIBILITY_VERSION,
                $input->{permission_version} || $DEFAULT_PERMISSION_VERSION,
                \@users,
            );
        }
    );

    return {
        ok        => 1,
        projected => scalar @users,
        written   => 0 + ( $written // 0 ),
    };
}

sub remove_item ( $self, $input ) {
    return $self->schema->txn_do(
        sub {
            return $self->_remove_item($input);
        }
    );
}

sub _remove_item ( $self, $input ) {
    if ( !_item_key($input) ) {
        return { ok => 1, removed => 0 };
    }

    my $deleted = $self->_delete_items( _item_query($input) );

    return { ok => 1, removed => $deleted || 0 };
}

sub remove_thread ( $self, $thread_id ) {
    return $self->schema->txn_do(
        sub {
            return $self->_remove_thread($thread_id);
        }
    );
}

# The thread row and every post row leave the feed together, otherwise a
# partial sweep keeps deleted posts visible in somebody's feed.
sub _remove_thread ( $self, $thread_id ) {
    my $thread_removed = $self->_remove_item(
        {
            item_id   => $thread_id,
            item_type => $THREAD_ITEM,
        }
    );

    return $self->_with_post_removals( $thread_id, $thread_removed );
}

sub _with_post_removals ( $self, $thread_id, $thread_removed ) {
    my $posts_removed = $self->_remove_thread_posts($thread_id);
    my $thread_count  = $thread_removed->{removed} || 0;

    return {
        ok            => 1,
        posts_removed => $posts_removed,
        removed       => $thread_count + $posts_removed,
    };
}

# Every post of the thread leaves every feed in one statement, by the
# (item_type, item_id) index (migration 047): it was one full scan of
# user_feed_items per post.
sub _remove_thread_posts ( $self, $thread_id ) {
    my $posts = $self->_post_resultset;
    return 0 if !$posts;

    return $self->_delete_items(
        {
            item_type => $POST_ITEM,
            item_id   => {
                -in => $posts->search_rs( { thread_id => $thread_id } )
                  ->get_column('post_id')
                  ->as_query
            },
        }
    );
}

sub _delete_items ( $self, $query ) {
    my $items = $self->_feed_resultset;
    if ( !$items ) {
        return 0;
    }

    my $deleted = $items->search_rs($query)->delete;

    return $deleted || 0;
}

sub _feed_resultset ($self) {
    return $self->schema->resultset('UserFeedItem');
}

sub _post_resultset ($self) {
    my $schema = $self->schema;
    if ( !$schema ) {
        return;
    }

    return $schema->resultset('Post');
}

sub _item_key ($input) {
    return defined $input->{item_type}
      && defined $input->{item_id} ? 1 : 0;
}

sub _item_query ($input) {
    return {
        item_id   => $input->{item_id},
        item_type => $input->{item_type},
    };
}

sub _unique_users ($users) {
    my %seen;

    return grep { defined && !$seen{$_}++ } @{$users};
}

1;

__END__

=head1 NAME

GPForum::Service::Community::FeedProjector - Write and remove items in members' personal feeds.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $projector =
      GPForum::Service::Community::FeedProjector->new( schema => $schema );

    $projector->project_item(
        {
            created_at => $created_at,
            item_id    => $post_id,
            item_type  => 'post',
            user_ids   => \@subscriber_ids,
        }
    );
    $projector->remove_item( { item_id => $post_id, item_type => 'post' } );
    $projector->remove_thread($thread_id);

=head1 DESCRIPTION

Maintains C<user_feed_items>, the per-member feed that
L<GPForum::Worker::Handler::FeedProjection> fills from domain events.

Projecting an item writes it for every recipient in one PostgreSQL
statement: the ids travel as one array, whatever their number, and each row
is inserted or refreshed in place, rows that already hold the item
unchanged being left alone. It used to read and write each recipient in
turn, two statements per subscriber of a popular thread in one ever longer
transaction.

Removing a thread takes the thread item and the items of all its posts out
of every feed together, the posts in one statement by the
C<(item_type, item_id)> index, so a partial sweep cannot leave deleted posts
in somebody's feed.

=head1 SUBROUTINES/METHODS

=head2 project_item

Takes a hash reference with C<item_type>, C<item_id>, C<created_at>,
C<user_ids> (an array reference; duplicates and undef are dropped), and
optional C<rank_score> (default 0), C<visibility_version> and
C<permission_version> (default 1). In a transaction, returns
C<< { ok => 1, projected, written } >>: the number of distinct recipients,
and of rows actually inserted or changed; both 0 without recipients.

=head2 remove_item

Takes a hash reference with C<item_type> and C<item_id>. In a transaction,
deletes that item from every feed. Returns C<< { ok => 1, removed } >> with
the rows deleted, 0 when either key is missing.

=head2 remove_thread

Takes a thread id. In a transaction, deletes the thread's item and its
posts' items from every feed. Returns
C<< { ok => 1, removed, posts_removed } >>, C<removed> counting both.

=head1 DIAGNOSTICS

None of its own; database errors propagate and roll the transaction back.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

None beyond L<GPForum::Base> and L<Const::Fast>. The upsert is PostgreSQL SQL
(C<unnest>, C<ON CONFLICT>, C<IS DISTINCT FROM>).

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
