# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Community::MentionReader;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Keyset;
use GPForum::Service::Forum::PageWindow;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT  => 25;
const my @CURSOR_COLUMNS => qw(created_at mention_id);

has page_window => sub { return GPForum::Service::Forum::PageWindow->new; };
has schema      => undef;

# ADR 0102: only rows whose post or thread the reader can still read, judged
# in the query before LIMIT. A mention kept pointing at a thread after its
# category turned private, showing its title to someone who lost access.
has readability => undef;

sub list_page_for_recipient ( $self, $user_id, $options ) {
    my $page   = $self->page_window->plan($options);
    my $search = $self->mentions_resultset(
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

# The resultset a mentions page executes; public so tests and the
# query-plan evidence see the SQL that runs.
sub mentions_resultset ( $self, $user_id, $options ) {
    my $query = {
        'me.mentioned_user_id' => $user_id,
        %{ $self->_readable_sources( $user_id, $options->{viewer} ) },
    };
    if ( $options->{after} ) {
        GPForum::Infrastructure::Keyset->after(
            $query,
            {
                direction => 'desc',
                id        => [ 'me.mention_id', $options->{after}{id} ],
                sort      => [ 'me.created_at', $options->{after}{sort_value} ],
            }
        );
    }

    return $self->schema->resultset('Mention')->search_rs(
        $query,
        {
            columns => [
                qw(
                  mention_id source_type source_id actor_id mentioned_user_id
                  mentioned_username created_at
                )
            ],
            join      => 'actor',
            '+select' => [ 'actor.username', 'actor.display_name' ],
            '+as'     => [qw(actor_username actor_display_name)],
            order_by  =>
              [ { -desc => 'me.created_at' }, { -desc => 'me.mention_id' } ],
            rows => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub _readable_sources ( $self, $user_id, $viewer ) {
    return {} if !$self->readability;

    return {
        -and => [
            $self->readability->sources_condition(
                $viewer // $user_id,
                'me.source_type', 'me.source_id'
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

GPForum::Service::Community::MentionReader - Keyset pages of the mentions of a member, filtered to what they can still read.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $reader = GPForum::Service::Community::MentionReader->new(
        readability => GPForum::Service::Forum::Readability->new(
            schema => $schema,
        ),
        schema => $schema,
    );
    my $page = $reader->list_page_for_recipient(
        $user_id,
        {
            after  => $cursor,
            limit  => 25,
            viewer => $viewer,
        }
    );
    # { items => [...], has_next => 0|1, next_cursor => ... }

=head1 DESCRIPTION

Reads the C<mentions> rows that name a member, newest first, ordered by
C<created_at> and then C<mention_id>, in keyset pages planned by
L<GPForum::Service::Forum::PageWindow>. Each row carries the mentioning
actor's C<username> and C<display_name> as C<actor_username> and
C<actor_display_name>.

When C<readability> is set, the query keeps only mentions whose post or
thread the reader can still read, judged in the query before C<LIMIT>
(ADR 0102), so a page stays full. A mention used to keep pointing at a
thread after its category turned private, showing its title to someone who
had lost access. Without C<readability> every mention of the member is
listed.

=head1 SUBROUTINES/METHODS

=head2 list_page_for_recipient

Takes the mentioned member's user id and a hash reference of options:
C<limit>, C<after> (the cursor string from the URL) and C<viewer> (the
reader to judge readability for; defaults to the user id). Returns the page
hash reference from L<GPForum::Service::Forum::PageWindow/page>: C<items>
(the rows), C<has_next> and C<next_cursor>.

=head2 mentions_resultset

Takes the user id and a hash reference with C<after> (an already decoded
C<< { sort_value, id } >>, or undef), C<limit> (default 25) and C<viewer>.
Returns the unexecuted C<Mention> resultset a page runs, joined to the
actor. Public so tests and the query-plan evidence see the SQL that runs.

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
