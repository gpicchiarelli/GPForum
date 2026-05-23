package GPForum::Service::Moderation::ReviewReader;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Forum::PageWindow;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT             => 25;
const my @ACTION_CURSOR_COLUMNS     => qw(created_at moderation_action_id);
const my @SUSPENSION_CURSOR_COLUMNS => qw(valid_from suspension_id);

has clock       => sub { return GPForum::Service::Clock->new; };
has page_window => sub { return GPForum::Service::Forum::PageWindow->new; };
has schema      => undef;

sub list_actions {
    my ( $self, $options ) = @_;

    $options ||= {};

    my $page  = $self->page_window->plan($options);
    my $query = _action_query(
        {
            after       => $page->{after},
            target_id   => $options->{target_id},
            target_type => $options->{target_type},
        }
    );

    my $search = $self->schema->resultset('ModerationAction')->search(
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

sub list_suspensions {
    my ( $self, $options ) = @_;

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

    my $search = $self->schema->resultset('Suspension')->search(
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

sub _action_query {
    my ($options) = @_;

    my $query = {};
    if ( _has_text( $options->{target_type} ) ) {
        $query->{target_type} = $options->{target_type};
    }
    if ( _has_text( $options->{target_id} ) ) {
        $query->{target_id} = $options->{target_id};
    }
    if ( $options->{after} ) {
        $query->{-or} =
          _descending_cursor_clause( $options->{after}, 'created_at',
            'moderation_action_id' );
    }

    return $query;
}

sub _suspension_query {
    my ($options) = @_;

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
          {
            -or => _descending_cursor_clause(
                $options->{after}, 'valid_from', 'suspension_id'
            )
          };
    }
    if (@clauses) {
        $query->{-and} = \@clauses;
    }

    return $query;
}

sub _active_valid_to_clause {
    my ($now) = @_;

    return {
        -or => [ { valid_to => undef }, { valid_to => { q{>=} => $now } }, ], };
}

sub _descending_cursor_clause {
    my ( $after, $sort_column, $id_column ) = @_;

    return [
        { $sort_column => { q{<} => $after->{sort_value} } },
        {
            -and => [
                { $sort_column => $after->{sort_value} },
                { $id_column   => { q{<} => $after->{id} } },
            ],
        },
    ];
}

sub _active_only {
    my ($options) = @_;

    my %inactive_modes = map { $_ => 1 } qw(:0 all: all:0);
    my $mode = join q{:}, _option_value( $options, 'status' ),
      _option_value( $options, 'active' );

    return exists $inactive_modes{$mode} ? 0 : 1;
}

sub _option_value {
    my ( $options, $name ) = @_;

    return q{} if !$options || !defined $options->{$name};

    return $options->{$name};
}

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value ? 1 : 0;
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
