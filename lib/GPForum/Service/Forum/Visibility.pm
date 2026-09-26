# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::Visibility;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $PUBLIC  => 'public';
const my $MEMBERS => 'members';
const my $PRIVATE => 'private';
const my %RANK    => ( $PUBLIC => 0, $MEMBERS => 1, $PRIVATE => 2 );

# ADR 0102. A resource's effective visibility is the most restrictive of its
# space, its category, its thread and, for a post, the post itself, ordered
# public < members < private. A missing or unknown value counts as private:
# every rule here fails closed.
sub effective ( $class, @levels ) {
    my $effective = $PUBLIC;
    for my $level (@levels) {
        my $known = defined $level && exists $RANK{$level} ? $level : $PRIVATE;
        if ( $RANK{$known} > $RANK{$effective} ) {
            $effective = $known;
        }
    }

    return $effective;
}

# Whether a visibility is broader -- less restrictive -- than a floor: a
# thread asking to be public in a members-only category, say. A floor that is
# missing or unknown counts as private, so it fails closed.
sub broader ( $class, $visibility, $floor ) {
    return $class->effective( $visibility, $floor ) ne ( $visibility // q{} )
      ? 1
      : 0;
}

# Whether a viewer may read one resource, given the visibility of each level
# and the ids that grants and authorship are judged by:
#   { space_visibility, category_visibility, thread_visibility,
#     post_visibility, category_id, space_id, thread_author, post_author }
# Thread and post levels are optional. An author reads their own non-public
# thread or post, but never past a space or category they cannot read.
sub readable ( $class, $viewer, $resource ) {
    my %scope = (
        category_id => $resource->{category_id},
        space_id    => $resource->{space_id},
    );
    return 0
      if !_level_readable( $viewer, $resource->{space_visibility}, \%scope );
    return 0
      if !_level_readable( $viewer, $resource->{category_visibility}, \%scope );

    for my $level (qw(thread post)) {
        next if !exists $resource->{"${level}_visibility"};
        return 0
          if !_level_readable(
            $viewer,
            $resource->{"${level}_visibility"},
            { %scope, authors => _authors( $level, $resource ) }
          );
    }

    return 1;
}

sub _level_readable ( $viewer, $visibility, $scope ) {
    my $level =
      defined $visibility && exists $RANK{$visibility} ? $visibility : q{};
    return 1                       if $level eq $PUBLIC;
    return $viewer->member ? 1 : 0 if $level eq $MEMBERS;
    return 0                       if $level ne $PRIVATE;

    return 1 if $viewer->granted( $scope->{category_id}, $scope->{space_id} );

    return _own( $viewer, $scope->{authors} );
}

# Who owns a level: its author, and for a post in a private thread the
# thread's author too -- the owner of a private thread reads the replies in
# it, or the thread would be useless to them.
sub _authors ( $level, $resource ) {
    my @authors = ( $resource->{"${level}_author"} );
    if ( $level eq 'post'
        && ( $resource->{thread_visibility} // q{} ) eq $PRIVATE )
    {
        push @authors, $resource->{thread_author};
    }

    return [ grep { defined } @authors ];
}

# Authorship reads a private thread or post only for a member: a suspended or
# deleted account does not keep it.
sub _own ( $viewer, $authors ) {
    return 0 if !$viewer->member || $viewer->is_anonymous;

    my $user_id = $viewer->user_id;

    return ( grep { $_ eq $user_id } @{ $authors || [] } ) ? 1 : 0;
}

# The same rule as an SQL condition for DBIx::Class, filtering in the query
# before LIMIT so keyset pages stay full (ADR 0102, Enforcement). $columns
# names the joined columns:
#   { space => 'space.visibility', category => 'category.visibility',
#     thread => 'me.visibility', post => ..., category_id => ...,
#     space_id => ..., thread_author => ..., post_author => ... }
# Levels left out are not constrained.
sub readable_condition ( $class, $viewer, $columns ) {
    my @conditions;
    for my $level (qw(space category thread post)) {
        next if !defined $columns->{$level};
        push @conditions,
          _level_condition(
            $viewer,
            $columns->{$level},
            {
                author       => $columns->{"${level}_author"},
                category_id  => $columns->{category_id},
                space_id     => $columns->{space_id},
                thread_owner => _thread_owner( $level, $columns ),
            }
          );
    }

    return { -and => \@conditions };
}

# For a post: its thread's author and visibility columns, when both are
# named. The owner of a private thread reads the replies in it, as _authors
# says for one row.
sub _thread_owner ( $level, $columns ) {
    my $undefined;
    return $undefined
      if $level ne 'post'
      || !defined $columns->{thread}
      || !defined $columns->{thread_author};

    return [ $columns->{thread_author}, $columns->{thread} ];
}

# The conditions under which a private row is readable: a grant on its
# category or its space, or authorship.
sub _private_grants ( $viewer, $scope ) {
    my @when;
    if ( defined $scope->{category_id} && @{ $viewer->category_ids } ) {
        push @when,
          { $scope->{category_id} => { -in => $viewer->category_ids } };
    }
    if ( defined $scope->{space_id} && @{ $viewer->space_ids } ) {
        push @when, { $scope->{space_id} => { -in => $viewer->space_ids } };
    }
    return @when if !$viewer->member || $viewer->is_anonymous;

    if ( defined $scope->{author} ) {
        push @when, { $scope->{author} => $viewer->user_id };
    }
    if ( my $owner = $scope->{thread_owner} ) {
        my ( $author, $visibility ) = @{$owner};
        push @when, { $author => $viewer->user_id, $visibility => $PRIVATE };
    }

    return @when;
}

sub _level_condition ( $viewer, $column, $scope ) {
    return { $column => { -in => [ $PUBLIC, $MEMBERS, $PRIVATE ] } }
      if $viewer->global_read;

    my @open         = $viewer->member ? ( $PUBLIC, $MEMBERS ) : ($PUBLIC);
    my @private_when = _private_grants( $viewer, $scope );

    return { $column => { -in => \@open } } if !@private_when;

    return {
        -or => [
            { $column => { -in => \@open } },
            { $column => $PRIVATE, -or => \@private_when },
        ]
    };
}

1;

__END__

=head1 NAME

GPForum::Service::Forum::Visibility - Effective visibility rules (ADR 0102).

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $level = GPForum::Service::Forum::Visibility->effective(
        $space_visibility, $category_visibility, $thread_visibility );
    my $ok = GPForum::Service::Forum::Visibility->readable( $viewer, \\%row );
    my $where = GPForum::Service::Forum::Visibility->readable_condition(
        $viewer,
        {
            space       => 'space.visibility',
            category    => 'category.visibility',
            category_id => 'category.category_id',
            space_id    => 'category.space_id',
        }
    );

=head1 DESCRIPTION

Owns the ordering of visibility levels, the most-restrictive rule, and the
rule for who may read what -- as a Perl check for one row and as an SQL
condition for lists. It has no schema access.

=head1 SUBROUTINES/METHODS

=head2 broader

True when a visibility is less restrictive than a floor.

=head2 effective

The most restrictive of the levels given; unknown counts as private.

=head2 readable

Whether a viewer may read one resource.

=head2 readable_condition

The same rule as a DBIx::Class condition over joined columns.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Forum::Viewer>.

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
