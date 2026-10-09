# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Domain::Post;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Domain::Thread;
use GPForum::Infrastructure::Row;

our $VERSION = '0.001';

# What each refusal of a post write means as a result status, beyond the
# thread's own (GPForum::Domain::Thread).
const my %STATUS => (
    'not the post author' => 'forbidden',
    'post is hidden'      => 'forbidden',
    'post not found'      => 'not_found',
);

# An edit or a delete needs a live post; a restore, a deleted one. Then a
# thread the author can read, their authorship, a post no moderator hid, and
# a thread that is not locked.
sub edit_refusal ( $class, $post, $thread, $author ) {
    return 'post not found'
      if !$post || defined _column( $post, 'deleted_at' );

    return _change_refusal( $post, $thread, $author );
}

sub restore_refusal ( $class, $post, $thread, $author ) {
    return 'post not found'
      if !$post || !defined _column( $post, 'deleted_at' );

    return _change_refusal( $post, $thread, $author );
}

sub hidden ( $class, $post ) {
    return 1 if defined _column( $post, 'hidden_at' );

    return ( _column( $post, 'moderation_state' ) // q{} ) eq 'hidden' ? 1 : 0;
}

sub status_of ( $class, $error ) {

    # exists first: reading an absent key of a constant hash dies.
    return $STATUS{$error} if exists $STATUS{ $error // q{} };

    return GPForum::Domain::Thread->status_of($error);
}

sub _change_refusal ( $post, $thread, $author ) {
    return 'thread not found' if !$thread;
    return 'not the post author'
      if !GPForum::Domain::Thread->by( $post, $author );
    return 'post is hidden'   if __PACKAGE__->hidden($post);
    return 'thread is locked' if GPForum::Domain::Thread->locked($thread);

    return undef;
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

1;

__END__

=head1 NAME

GPForum::Domain::Post - The rules that let an author edit, delete or restore a post.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use GPForum::Domain::Post;

    my $error = GPForum::Domain::Post->edit_refusal( $post, $thread, $user_id );
    return { status => GPForum::Domain::Post->status_of($error),
        error => $error } if $error;

=head1 DESCRIPTION

One definition of each rule that an author's edit, delete or restore of a
post is checked against, for L<GPForum::Service::Forum::PostingWorkflow>
before the transaction and L<GPForum::Service::Forum::PostStore> under its
row locks. Each refusal is the error string that both answer with, or undef
when the write may go ahead. The thread passed in is one the author can read
(see L<GPForum::Domain::Thread/shown_to_writer>), or undef.

Rows are hash references or L<DBIx::Class> rows, read with
L<GPForum::Infrastructure::Row/column>.

=head1 SUBROUTINES/METHODS

Class methods.

=head2 edit_refusal

Takes a post, its thread and the author's user id, for an edit or a delete.
Returns, in this order: C<post not found> when the post is missing or has a
C<deleted_at>; C<thread not found> when the thread is undef;
C<not the post author> when the post's C<author_user_id> is not the user id
(L<GPForum::Domain::Thread/by>); C<post is hidden> (L</hidden>);
C<thread is locked> when the thread has a C<locked_at>. Undef otherwise.

=head2 restore_refusal

As L</edit_refusal>, except that the post must be deleted: a missing or
live one is C<post not found>.

=head2 hidden

Takes a post. Returns 1 when it has a C<hidden_at> or its
C<moderation_state> is C<hidden>, else 0.

=head2 status_of

Takes a refusal and returns the result status it means: C<not_found> for
C<post not found>, C<forbidden> for C<not the post author> and
C<post is hidden>, and the thread's statuses
(L<GPForum::Domain::Thread/status_of>) for the thread's words. Undef for
anything else.

=head1 DIAGNOSTICS

None: a refusal is a return value.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>, L<Const::Fast>, L<GPForum::Domain::Thread>,
L<GPForum::Infrastructure::Row>.

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
