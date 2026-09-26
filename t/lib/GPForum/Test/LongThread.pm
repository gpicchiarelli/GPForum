# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::LongThread;

use strict;
use warnings;

our $VERSION = '0.001';

# Posts appended to a seeded thread on PostgreSQL until it has $posts, each
# with the body the search document builder reads, at the positions after
# the thread's last.
sub grow {
    my ( $dbh, $thread_id, $posts ) = @_;

    $dbh->do(
        q{INSERT INTO posts (post_id, thread_id, author_user_id, position)}
          . q{ SELECT gen_random_uuid(), t.thread_id, t.author_user_id,}
          . q{ (SELECT coalesce(max(position), 0) FROM posts}
          . q{ WHERE thread_id = t.thread_id) + n FROM threads t,}
          . q{ generate_series(1, ? - (SELECT count(*) FROM posts}
          . q{ WHERE thread_id = ?)) AS n WHERE t.thread_id = ?},
        undef, $posts, $thread_id, $thread_id
    );
    $dbh->do(
        q{INSERT INTO post_bodies (body_id, post_id, body_source,}
          . q{ body_rendered_safe, source_hash) SELECT gen_random_uuid(),}
          . q{ post_id, 'Another reply', 'Another reply', md5(post_id::text)}
          . q{ FROM posts WHERE thread_id = ? AND current_body_id IS NULL},
        undef, $thread_id
    );
    $dbh->do(
        q{UPDATE posts SET current_body_id = b.body_id FROM post_bodies b}
          . q{ WHERE b.post_id = posts.post_id AND posts.thread_id = ?}
          . q{ AND posts.current_body_id IS NULL},
        undef, $thread_id
    );

    return;
}

1;
