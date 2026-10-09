# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::UrlId;

use Mojo::Base -base, -signatures;
use v5.40;

use Const::Fast;

use GPForum::Infrastructure::Id;

our $VERSION = '0.001';

# A route placeholder naming a row: thread_id, post_id, report_id...
const my $ID_PLACEHOLDER => qr/_id\z/msx;

# Every *_id column is a uuid (tables keyed otherwise -- version, role_name,
# key -- are not addressed by an *_id placeholder), so an id from the URL
# without that shape names nothing. PostgreSQL refuses the whole statement
# that binds it -- the permission gate's role-binding lookup as well as the
# store's -- and the routes answered 500 or 503 for what is a 404.
sub malformed_path_id ( $class, $controller ) {
    for my $name ( $class->_path_id_names($controller) ) {
        if (
            !GPForum::Infrastructure::Id->is_uuid( $controller->stash($name) ) )
        {
            return $name;
        }
    }

    return;
}

sub malformed ( $class, $value ) {
    if ( !defined $value || !length $value ) {
        return 0;
    }

    return GPForum::Infrastructure::Id->is_uuid($value) ? 0 : 1;
}

# A malformed id answers as one naming no row, word for word. Where the
# workflow names the row more fully than the placeholder does (action_id is a
# "moderation action"), the caller passes that noun: the derived "action not
# found" was a second answer for the same missing row.
sub not_found_error ( $class, $name, $nouns = {} ) {
    my $key = $name // q{};
    my $noun;
    if ( exists $nouns->{$key} ) {
        $noun = $nouns->{$key};
    }
    else {
        ( $noun = $key ) =~ s/$ID_PLACEHOLDER//msx;
        $noun =~ tr/_/ /;
    }

    return length $noun ? "$noun not found" : 'not found';
}

# The placeholders of the matched route and of the routes it is nested in.
sub _path_id_names ( $class, $controller ) {
    my $match = $controller->match;
    my $route = $match ? $match->endpoint : undef;
    my @names;

    while ($route) {
        push @names,
          grep { $_ =~ $ID_PLACEHOLDER } @{ $route->pattern->placeholders };
        $route = $route->parent;
    }

    return @names;
}

1;

__END__

=head1 NAME

GPForum::Web::UrlId - Refuses ids from the URL that cannot name a row.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    if ( my $name = GPForum::Web::UrlId->malformed_path_id($controller) ) {
        return GPForum::Web::Guard->new->not_found( $controller,
            GPForum::Web::UrlId->not_found_error($name) );
    }

=head1 DESCRIPTION

Rows are keyed by uuid. An id taken from the URL that does not have the
shape of one names no row, and binding it in a query makes PostgreSQL refuse
the statement, so a controller asks here first and answers 404 without
touching the database.

=head1 SUBROUTINES/METHODS

=head2 malformed_path_id

Returns the name of the first route placeholder ending in C<_id> (in the
matched route or a route it is nested in) whose captured value is not a
uuid, or nothing when every such capture is one. Routes without such a
placeholder always pass.

=head2 malformed

True when a value is given (defined and not empty) and is not a uuid. Used
for optional id filters in the query string, where an empty value means no
filter.

=head2 not_found_error

The error message for a malformed placeholder, worded like the workflows'
own for a missing row and derived from its name: C<thread_id> gives
C<thread not found>. An optional hash reference maps placeholders to the
noun the workflow uses where the name alone says less: with
C<< { action_id => 'moderation action' } >>, C<action_id> gives
C<moderation action not found>. Only C<exists> is asked of it, so a
L<Const::Fast> hash may be passed.

=head1 DIAGNOSTICS

Returns values only; the caller renders the response.

=head1 CONFIGURATION AND ENVIRONMENT

No environment variables are read.

=head1 DEPENDENCIES

Uses L<GPForum::Infrastructure::Id> for the uuid shape.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Only placeholders named C<*_id> are checked; slugs and usernames are not ids.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
