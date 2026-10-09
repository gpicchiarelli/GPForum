# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Domain::Thread;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Infrastructure::Row;

our $VERSION = '0.001';

# ThreadDetailReader shows a thread only in these moderation states.
const my %SHOWN_STATE => ( locked => 1, visible => 1 );

# What each refusal of a thread write means as a result status. The words are
# the ones a refusal below returns; a post's refusals add theirs in
# GPForum::Domain::Post.
const my %STATUS => (
    'not the thread author' => 'forbidden',
    'thread is hidden'      => 'forbidden',
    'thread is locked'      => 'forbidden',
    'thread not found'      => 'not_found',
);

# The thread as ThreadDetailReader shows it to the writer as a viewer, or
# undef: a state it does not show is unreadable, and so is a deleted thread
# to anyone but its author.
sub shown_to_writer ( $class, $thread, $writer ) {
    return undef if !$thread;
    return undef
      if !exists $SHOWN_STATE{ _column( $thread, 'moderation_state' ) // q{} };
    return $thread if !defined _column( $thread, 'deleted_at' );
    return $thread
      if length( $writer // q{} ) && $class->by( $thread, $writer );

    return undef;
}

# A reply needs a thread its writer can read, and one that is not locked.
sub reply_refusal ( $class, $thread ) {
    return 'thread not found' if !$thread;
    return 'thread is locked' if _locked($thread);

    return undef;
}

# A title edit, a move or a delete needs a live thread; a restore, a deleted
# one. Then only its author may change it, and not while it is hidden or
# locked.
sub edit_refusal ( $class, $thread, $author ) {
    return 'thread not found'
      if !$thread || defined _column( $thread, 'deleted_at' );

    return _change_refusal( $class, $thread, $author );
}

sub restore_refusal ( $class, $thread, $author ) {
    return 'thread not found'
      if !$thread || !defined _column( $thread, 'deleted_at' );

    return _change_refusal( $class, $thread, $author );
}

# Whether the row's author_user_id is this user. An absent author and an
# empty user are the same nobody.
sub by ( $class, $row, $user_id ) {
    return ( _column( $row, 'author_user_id' ) // q{} ) eq ( $user_id // q{} )
      ? 1
      : 0;
}

sub locked ( $class, $thread ) {
    return _locked($thread);
}

sub status_of ( $class, $error ) {

    # exists first: reading an absent key of a constant hash dies.
    return exists $STATUS{ $error // q{} } ? $STATUS{$error} : undef;
}

sub _change_refusal ( $class, $thread, $author ) {
    return 'not the thread author' if !$class->by( $thread, $author );
    return 'thread is hidden'
      if ( _column( $thread, 'moderation_state' ) // q{} ) eq 'hidden';
    return 'thread is locked' if _locked($thread);

    return undef;
}

sub _locked ($thread) {
    return defined _column( $thread, 'locked_at' ) ? 1 : 0;
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

1;

__END__

=head1 NAME

GPForum::Domain::Thread - The rules that let a writer reply to, change, delete or restore a thread.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use GPForum::Domain::Thread;

    my $error = GPForum::Domain::Thread->reply_refusal(
        GPForum::Domain::Thread->shown_to_writer( $locked_row, $user_id ) );
    return { ok => 0, error => $error } if $error;

    my $status = GPForum::Domain::Thread->status_of($error);   # not_found

=head1 DESCRIPTION

One definition of each rule that a thread write is checked against, for the
two places that ask it: L<GPForum::Service::Forum::PostingWorkflow> before
the transaction, with the thread its reader returned, and the stores under
their row locks, with the row the lock returned. Each refusal is the error
string that both answer with, or undef when the write may go ahead.

A thread is a hash reference or a L<DBIx::Class> row; columns are read with
L<GPForum::Infrastructure::Row/column>.

=head1 SUBROUTINES/METHODS

Class methods.

=head2 shown_to_writer

Takes a thread and the writer's user id. Returns the thread when
L<GPForum::Service::Forum::ThreadDetailReader> would show it to the writer,
else undef: its C<moderation_state> must be C<visible> or C<locked>, and a
thread with a C<deleted_at> is shown only to its author (a non-empty writer
equal to its C<author_user_id>). The workflow's reader has already made that
choice; a store asks it of the row its lock returned.

=head2 reply_refusal

Takes a thread the writer can read, or undef. Returns C<thread not found>
for undef, C<thread is locked> when it has a C<locked_at>, else undef.

=head2 edit_refusal

Takes a thread the writer can read (or undef) and the writer's user id, for
a title edit, a move or a delete. Returns, in this order,
C<thread not found> (undef, or deleted), C<not the thread author>,
C<thread is hidden> (C<moderation_state> C<hidden>) or C<thread is locked>;
else undef.

=head2 restore_refusal

As L</edit_refusal>, except that the thread must be deleted: a live one is
C<thread not found>.

=head2 by

Takes a row and a user id. Returns 1 when the row's C<author_user_id> equals
the user id, an undefined one counting as empty, else 0.

=head2 locked

Takes a thread. Returns 1 when it has a C<locked_at>, else 0.

=head2 status_of

Takes a refusal and returns the result status it means: C<not_found> for
C<thread not found>, C<forbidden> for C<not the thread author>,
C<thread is hidden> and C<thread is locked>. Undef for anything else.

=head1 DIAGNOSTICS

None: a refusal is a return value.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>, L<Const::Fast>, L<GPForum::Infrastructure::Row>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

L<GPForum::Service::Forum::ThreadStore> still re-checks a thread's own
writes with its own words (a hidden thread is C<thread not found> there).

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
