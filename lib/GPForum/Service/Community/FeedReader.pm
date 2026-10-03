# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Community::FeedReader;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Infrastructure::Keyset;
use GPForum::Service::Forum::PageWindow;
use GPForum::Service::Forum::SourceThread;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT  => 25;
const my @CURSOR_COLUMNS => qw(created_at item_id);

has page_window => sub { return GPForum::Service::Forum::PageWindow->new; };
has schema      => undef;

# ADR 0102: only rows whose post or thread the reader can still read, judged
# in the query before LIMIT. A feed item kept pointing at a thread after its
# category turned private, showing its title to someone who lost access.
has readability => undef;

sub list_page_for_user ( $self, $user_id, $options ) {
    my $page   = $self->page_window->plan($options);
    my $search = $self->feed_resultset(
        $user_id,
        {
            %{ $options || {} },
            limit => $page->{fetch_rows},
            after => $page->{after},
        }
    );

    my @rows = _rows($search);

    return $self->page_window->page( \@rows, $page->{limit}, \@CURSOR_COLUMNS );
}

# The resultset a feed page executes.
# Public so the query-plan evidence EXPLAINs what actually runs.
sub feed_resultset ( $self, $user_id, $options ) {
    my $query = {
        user_id => $user_id,
        %{ $self->_readable_items( $user_id, $options->{viewer} ) },
    };
    if ( $options->{after} ) {
        GPForum::Infrastructure::Keyset->after(
            $query,
            {
                direction => 'desc',
                id        => [ 'item_id',    $options->{after}{id} ],
                sort      => [ 'created_at', $options->{after}{sort_value} ],
            }
        );
    }

    return $self->schema->resultset('UserFeedItem')->search_rs(
        $query,
        {
            columns => [
                qw(
                  user_id item_type item_id created_at rank_score
                  visibility_version permission_version
                )
            ],
            GPForum::Service::Forum::SourceThread->attributes(
                $self->readability, 'me.item_type', 'me.item_id'
            ),
            order_by => [ { -desc => 'created_at' }, { -desc => 'item_id' } ],
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub _readable_items ( $self, $user_id, $viewer ) {
    return {} if !$self->readability;

    return {
        -and => [
            $self->readability->sources_condition(
                $viewer // $user_id,
                'me.item_type', 'me.item_id'
            )
        ]
    };
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Community::FeedReader - Keyset pages of a member's personal feed, filtered to what they can still read.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $reader = GPForum::Service::Community::FeedReader->new(
        readability => GPForum::Service::Forum::Readability->new(
            schema => $schema,
        ),
        schema => $schema,
    );
    my $page = $reader->list_page_for_user(
        $user_id,
        {
            limit  => 25,
            after  => $cursor,
            viewer => $viewer,
        }
    );
    # { items => [...], has_next => 0|1, next_cursor => ... }

=head1 DESCRIPTION

Reads a member's C<user_feed_items> rows newest first, ordered by
C<created_at> and then C<item_id>, in keyset pages planned by
L<GPForum::Service::Forum::PageWindow>.

When C<readability> is set, the query keeps only items whose post or
thread the reader can still read, judged in the query before C<LIMIT>
(ADR 0102), so a page stays full. A feed item used to keep pointing at a
thread after its category turned private, showing its title to someone who
had lost access. Without C<readability> every item of the member is
listed.

=head1 SUBROUTINES/METHODS

=head2 list_page_for_user

Takes the member's user id and a hash reference of options: C<limit>,
C<after> (the cursor string from the URL) and C<viewer> (the reader to
judge readability for; defaults to the user id). Returns the page hash
reference from L<GPForum::Service::Forum::PageWindow/page>: C<items> (the
rows), C<has_next> and C<next_cursor>.

=head2 feed_resultset

Takes the user id and a hash reference with C<after> (an already decoded
C<< { sort_value, id } >>, or undef), C<limit> (default 25) and C<viewer>.
Returns the unexecuted C<UserFeedItem> resultset a page runs, selecting
C<user_id>, C<item_type>, C<item_id>, C<created_at>, C<rank_score>,
C<visibility_version> and C<permission_version>. Public so the query-plan
evidence EXPLAINs what actually runs. When C<readability> is set, each row
also carries the thread it is about, C<source_thread_id> and
C<source_thread_title> (L<GPForum::Service::Forum::SourceThread>); without
it neither is selected, since the list is then not cut to what the reader
may read.

=head1 DIAGNOSTICS

Nothing of its own: an unacceptable cursor shows the first page, and
database errors propagate from the schema.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::Keyset>, L<GPForum::Service::Forum::PageWindow>,
L<GPForum::Service::Forum::Readability> (passed in as C<readability>).

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
