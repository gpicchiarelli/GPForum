# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::PostPosition;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

const my $FIRST_POSITION => 1;
const my $UNSAFE_NEXT_POSITION_MESSAGE =>
'PostPosition::next_position is unsafe for writes; use PostStore deferred allocation';

has schema => undef;

sub next_position {
    croak $UNSAFE_NEXT_POSITION_MESSAGE;
}

sub read_next_position ( $self, $thread_id ) {
    my $posts  = $self->schema->resultset('Post');
    my $search = $posts->search_rs(
        { thread_id => $thread_id },
        {
            order_by => [ { -desc => 'position' }, { -desc => 'post_id' }, ],
            rows     => 1,
        }
    );
    my $latest = $search->single;

    return $FIRST_POSITION if !$latest;

    return $latest->get_column('position') + 1;
}

1;

__END__

=head1 NAME

GPForum::Service::Forum::PostPosition - Read the next free post position of a thread.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $positions = GPForum::Service::Forum::PostPosition->new(
        schema => $schema,
    );
    my $next = $positions->read_next_position($thread_id);

=head1 DESCRIPTION

Reads the position the next post of a thread would take. It is not an
allocator: two writers reading the same value would give their posts the
same position, so a write takes its position from
L<GPForum::Service::Forum::PostStore>, which hands positions out under the
thread's row lock in commit order. The old C<next_position> name now
refuses to run.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor. C<schema> is the DBIx::Class schema.

=head2 next_position

Always croaks. Kept so a caller that still uses the old allocator name fails
loudly instead of racing.

=head2 read_next_position

Takes a thread id. Returns one more than the highest C<position> among the
thread's posts (ties broken by the highest C<post_id>), or 1 when the thread
has no posts.

=head1 DIAGNOSTICS

C<next_position> croaks with
C<PostPosition::next_position is unsafe for writes; use PostStore deferred
allocation>. Database errors from C<read_next_position> propagate.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Forum::PostStore> owns the write path.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The value C<read_next_position> returns can be stale by the time it is used;
it must not be written as a post's position.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
