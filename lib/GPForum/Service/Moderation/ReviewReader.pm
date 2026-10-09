# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Moderation::ReviewReader;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::Keyset;
use GPForum::Service::Forum::PageWindow;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT             => 25;
const my @ACTION_CURSOR_COLUMNS     => qw(created_at moderation_action_id);
const my @SUSPENSION_CURSOR_COLUMNS => qw(valid_from suspension_id);

has clock       => sub { return GPForum::Service::Clock->new; };
has page_window => sub { return GPForum::Service::Forum::PageWindow->new; };
__PACKAGE__->requires(qw(schema));

sub list_actions ( $self, $options ) {
    $options ||= {};

    my $page  = $self->page_window->plan($options);
    my $query = _action_query(
        {
            after       => $page->{after},
            target_id   => $options->{target_id},
            target_type => $options->{target_type},
        }
    );

    my $search = $self->schema->resultset('ModerationAction')->search_rs(
        $query,
        {
            columns => [
                qw(
                  moderation_action_id actor_user_id action_type
                  target_type target_id reason metadata created_at
                  reversed_at reversed_by_user_id
                )
            ],
            order_by => [
                { -desc => 'created_at' },
                { -desc => 'moderation_action_id' },
            ],
            rows => $page->{fetch_rows} || $DEFAULT_LIMIT,
        }
    );

    my @rows = _rows($search);

    return $self->page_window->page( \@rows,
        $page->{limit}, \@ACTION_CURSOR_COLUMNS );
}

sub list_suspensions ( $self, $options ) {
    $options ||= {};

    my $page  = $self->page_window->plan($options);
    my $query = _suspension_query(
        {
            active_only => _active_only($options),
            after       => $page->{after},
            now         => $self->clock->now_iso8601,
            user_id     => $options->{user_id},
        }
    );

    my $search = $self->schema->resultset('Suspension')->search_rs(
        $query,
        {
            columns => [
                qw(
                  suspension_id user_id actor_user_id reason valid_from
                  valid_to revoked_at metadata
                )
            ],
            order_by =>
              [ { -desc => 'valid_from' }, { -desc => 'suspension_id' }, ],
            rows => $page->{fetch_rows} || $DEFAULT_LIMIT,
        }
    );

    my @rows = _rows($search);

    return $self->page_window->page( \@rows,
        $page->{limit}, \@SUSPENSION_CURSOR_COLUMNS );
}

sub _action_query ($options) {
    my $query = {};
    if ( _has_text( $options->{target_type} ) ) {
        $query->{target_type} = $options->{target_type};
    }
    if ( _has_text( $options->{target_id} ) ) {
        $query->{target_id} = $options->{target_id};
    }
    if ( $options->{after} ) {
        GPForum::Infrastructure::Keyset->after(
            $query,
            {
                direction => 'desc',
                id        => [ 'moderation_action_id', $options->{after}{id} ],
                sort      => [ 'created_at', $options->{after}{sort_value} ],
            }
        );
    }

    return $query;
}

sub _suspension_query ($options) {
    my $query = {};
    my @clauses;
    if ( $options->{active_only} ) {
        $query->{revoked_at} = undef;
        push @clauses, _active_valid_to_clause( $options->{now} );
    }
    if ( _has_text( $options->{user_id} ) ) {
        $query->{user_id} = $options->{user_id};
    }
    if ( $options->{after} ) {
        push @clauses,
          GPForum::Infrastructure::Keyset->after(
            {},
            {
                direction => 'desc',
                id        => [ 'suspension_id', $options->{after}{id} ],
                sort      => [ 'valid_from',    $options->{after}{sort_value} ],
            }
          );
    }
    if (@clauses) {
        $query->{-and} = \@clauses;
    }

    return $query;
}

sub _active_valid_to_clause ($now) {
    return {
        -or => [ { valid_to => undef }, { valid_to => { q{>=} => $now } }, ], };
}

sub _active_only ($options) {
    my %inactive_modes = map { $_ => 1 } qw(:0 all: all:0);
    my $mode = join q{:}, _option_value( $options, 'status' ),
      _option_value( $options, 'active' );

    return exists $inactive_modes{$mode} ? 0 : 1;
}

sub _option_value ( $options, $name ) {
    return q{} if !$options || !defined $options->{$name};

    return $options->{$name};
}

sub _has_text ($value) {
    return defined $value && length $value ? 1 : 0;
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Moderation::ReviewReader - Keyset-paged moderation action history and suspension list.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $reader =
      GPForum::Service::Moderation::ReviewReader->new( schema => $schema );

    my $actions = $reader->list_actions(
        { limit => 25, target_id => $post_id, target_type => 'post' } );
    my $older = $reader->list_actions( { after => $actions->{next_cursor} } );

    my $suspensions =
      $reader->list_suspensions( { status => 'all', user_id => $user_id } );

=head1 DESCRIPTION

The read side of the moderation review screens. Both lists are newest first
and keyset paged through L<GPForum::Service::Forum::PageWindow>, so a deep
page costs the same as the first: actions on C<created_at> and
C<moderation_action_id>, suspensions on C<valid_from> and C<suspension_id>.
By default the suspension list holds only active suspensions: not revoked,
with no C<valid_to> or one not yet past.

=head1 SUBROUTINES/METHODS

=head2 list_actions

Takes an optional hash reference with C<limit>, C<after> (a cursor from a
previous page), and C<target_type> and C<target_id> filters, ignored when
empty. Returns C<< { items, has_next, next_cursor } >>, the items being
C<moderation_actions> rows with the action's id, actor, type, target,
reason, metadata, creation time and reversal columns.

=head2 list_suspensions

Takes an optional hash reference with C<limit>, C<after>, C<user_id>,
C<status> and C<active>. Lists active suspensions only, unless C<status> is
C<all> and C<active> is absent or 0, or C<active> is 0 and C<status> is
absent. Returns the page hash as C<list_actions> does, the items being
C<suspensions> rows.

=head1 DIAGNOSTICS

None of its own; database errors propagate. A cursor that cannot be decoded
gives the first page.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::Keyset>, L<GPForum::Service::Forum::PageWindow>,
L<GPForum::Service::Clock>.

Extends L<GPForum::Base>: built without C<schema> it throws
L<GPForum::X::Argument>.

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
