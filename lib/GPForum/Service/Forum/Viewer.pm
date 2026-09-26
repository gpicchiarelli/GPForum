# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::Viewer;

use strict;
use warnings;

use List::Util qw(any);
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

# Who is reading, as far as visibility cares (ADR 0102). Anonymous by default:
# every attribute that widens what can be read has to be established.
has user_id      => undef;
has member       => 0;
has global_read  => 0;
has category_ids => sub { return []; };
has space_ids    => sub { return []; };

sub anonymous ($class) {
    return $class->new;
}

# A viewer from what a caller has: a Viewer as it is, a bare user id as a
# non-member with that id -- it keeps authorship, and nothing that needs the
# account resolved -- and nothing as anonymous. Never wider than the truth.
sub from ( $class, $given ) {
    return $given if ref $given && eval { $given->isa($class) };
    return $class->new( user_id => $given )
      if defined $given && !ref $given && length $given;

    return $class->anonymous;
}

sub is_anonymous ($self) {
    return defined $self->user_id && length $self->user_id ? 0 : 1;
}

# Whether a category.read grant covers this category: globally, through its
# space, or on the category itself.
sub granted ( $self, $category_id, $space_id ) {
    return 1 if $self->global_read;

    return 1 if _listed( $category_id, $self->category_ids );

    return _listed( $space_id, $self->space_ids );
}

sub _listed ( $id, $ids ) {
    return 0 if !defined $id;

    return ( any { $_ eq $id } @{$ids} ) ? 1 : 0;
}

# This viewer with its grants decided for one category: a grant that covers
# it becomes a global read, any other is dropped. For conditions on rows
# already known to sit in that category -- a thread's posts -- which then need
# no join to their category or space.
sub within ( $self, $category_id, $space_id ) {
    return ( ref $self )->new(
        global_read => $self->granted( $category_id, $space_id ),
        member      => $self->member,
        user_id     => $self->user_id,
    );
}

1;

__END__

=head1 NAME

GPForum::Service::Forum::Viewer - Who is reading, for effective visibility.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $viewer = GPForum::Service::Forum::Viewer->anonymous;
    $viewer->granted( $category_id, $space_id );

=head1 DESCRIPTION

The reader of a page as ADR 0102 sees them: anonymous, a member (an active or
pending account, not suspended), and the scopes of their C<category.read>
grants. Built by L<GPForum::Service::Forum::ViewerResolver>; judged by
L<GPForum::Service::Forum::Visibility>.

=head1 SUBROUTINES/METHODS

=head2 anonymous

A viewer who can read public content only.

=head2 from

A viewer from a Viewer, a bare user id (a non-member) or nothing (anonymous).

=head2 is_anonymous

True without a user id.

=head2 granted

True when a C<category.read> grant covers the category.

=head2 within

The viewer with its grants decided for one category.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>.

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
