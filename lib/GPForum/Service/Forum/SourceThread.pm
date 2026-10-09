# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::SourceThread;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# A bookmark, a feed item, a mention and a notification each point at a
# source, a thread or a post, by its type and id. A list that shows them has
# to say which discussion each one is about, and until it could, it showed
# the id. These are the columns that name it: the thread the source is, or
# the one its post belongs to, and that thread's title. Each is a lookup by
# primary key, for each row of the page, inside the page's own statement.
#
# A title is content. The columns are added only to a list already cut to
# what its reader may read (ADR 0102): one that is not still names a thread
# they lost access to, and must not also say what it is called.
sub attributes ( $class, $readable, $type, $id ) {
    return if !$readable;

    my $thread_id = _thread_id( $type, $id );
    my $title     = _title($thread_id);

    return (
        '+columns' => [
            { source_thread_id    => \$thread_id },
            { source_thread_title => \$title },
        ]
    );
}

# $type and $id are column names the calling reader writes, never input.
sub _thread_id ( $type, $id ) {
    return <<"SQL";
CASE $type
  WHEN 'thread' THEN $id
  WHEN 'post' THEN (SELECT post.thread_id
                      FROM posts post
                     WHERE post.post_id = $id)
END
SQL
}

sub _title ($thread_id) {
    return <<"SQL";
(SELECT thread.title
   FROM threads thread
  WHERE thread.thread_id = $thread_id)
SQL
}

1;

__END__

=head1 NAME

GPForum::Service::Forum::SourceThread - The thread a listed source is about.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $bookmarks = $schema->resultset('Bookmark')->search_rs(
        $query,
        {
            GPForum::Service::Forum::SourceThread->attributes(
                $self->readability, 'me.target_type', 'me.target_id'
            ),
            rows => $limit,
        }
    );

    $row->get_column('source_thread_title');

=head1 DESCRIPTION

Bookmarks, feed items, mentions and notifications point at a thread or a
post by a type column and an id column. This module gives a reader of such
rows the resultset attributes that add, to each row, the thread the source
is or belongs to: C<source_thread_id> and C<source_thread_title>. Both are
undef for a source that is neither a thread nor a post, and for one whose
thread or post no longer exists.

=head1 SUBROUTINES/METHODS

=head2 attributes

Takes whether the list is cut to what its reader may read, and the names of
the type and id columns as the resultset's SQL writes them
(C<me.target_type>, C<notification.source_id>). Returns a list to place in a
resultset's attributes, which is empty when the first argument is false: a
list that is not filtered for readability gets no title.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Mojo::Base>. The SQL names the C<threads> and C<posts> tables.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The column names are interpolated into SQL, so they must be written by the
calling code and never taken from a request. The title is the thread's
current one, read when the page is: it is not what the thread was called
when the row was written.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
