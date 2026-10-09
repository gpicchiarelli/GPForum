# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RowReader;

use v5.40;

our $VERSION = '0.001';

# The workflow's readers over one post and one thread row. find_thread
# answers as ThreadDetailReader does for the writer, written out here rather
# than asked of GPForum::Domain::Thread: only visible and locked threads, and
# a deleted one to its author only.
sub new ( $class, %row ) {
    return bless {%row}, $class;
}

sub find_post ( $self, $post_id ) {
    return $self->{post} ? { %{ $self->{post} } } : undef;
}

sub find_thread ( $self, $thread_id, $viewer ) {
    my $thread = $self->{thread};
    return undef if !$thread;

    my $state = $thread->{moderation_state} // q{};
    return undef if $state ne 'visible' && $state ne 'locked';
    return undef
      if defined $thread->{deleted_at}
      && ( $thread->{author_user_id} // q{} ) ne $self->{writer};

    return { %{$thread} };
}

1;
