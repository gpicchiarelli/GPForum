package GPForum::Service::Identity::ProfileReader;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Forum::PageWindow;

our $VERSION = '0.001';

const my $DEFAULT_THREAD_LIMIT  => 10;
const my @THREAD_CURSOR_COLUMNS => qw(last_activity_at thread_id);

has page_window => sub { return GPForum::Service::Forum::PageWindow->new; };
has schema      => undef;

sub public_profile {
    my ( $self, $username, $options ) = @_;

    my $user = $self->_find_public_user($username);
    return { ok => 0, error => 'not_found' } if !$user;

    my $threads = $self->_recent_public_threads( $user, $options || {} );

    return {
        ok      => 1,
        profile => {
            user    => _user_hash($user),
            trust   => $self->_trust_hash($user),
            threads => $threads,
        },
    };
}

sub _find_public_user {
    my ( $self, $username ) = @_;

    my $user = $self->schema->resultset('User')
      ->find( { username => _normalize_username($username) } );

    return if !$user;
    return if defined _column( $user, 'deleted_at' );
    return if ( _column( $user, 'status' ) || q{} ) eq 'suspended';

    return $user;
}

sub _trust_hash {
    my ( $self, $user ) = @_;

    my $snapshot =
      $self->schema->resultset('TrustScoreSnapshot')
      ->find( _column( $user, 'id' ) );

    return {
        score       => _column( $snapshot, 'score' ) || 0,
        trust_level => _column( $snapshot, 'trust_level' )
          || _column( $user, 'trust_level' )
          || 0,
        calculated_at => _column( $snapshot, 'calculated_at' ),
        version       => _column( $snapshot, 'version' ) || 1,
    };
}

sub _recent_public_threads {
    my ( $self, $user, $options ) = @_;

    my $page   = $self->page_window->plan($options);
    my $query  = _thread_query( _column( $user, 'id' ), $page->{after} );
    my $search = $self->schema->resultset('Thread')->search(
        $query,
        {
            columns => [
                qw(
                  thread_id category_id author_user_id title slug visibility
                  moderation_state last_activity_at created_at
                )
            ],
            order_by =>
              [ { -desc => 'last_activity_at' }, { -desc => 'thread_id' } ],
            rows => $page->{fetch_rows} || $DEFAULT_THREAD_LIMIT,
        }
    );

    my @rows   = _rows($search);
    my $window = $self->page_window->page( \@rows, $page->{limit},
        \@THREAD_CURSOR_COLUMNS );

    return {
        items       => [ map { _thread_hash($_) } @{ $window->{items} } ],
        next_cursor => $window->{next_cursor},
    };
}

sub _thread_query {
    my ( $user_id, $after ) = @_;

    my $query = {
        author_user_id   => $user_id,
        deleted_at       => undef,
        moderation_state => 'visible',
        visibility       => 'public',
    };
    if ($after) {
        $query->{-or} = [
            { last_activity_at => { q{<} => $after->{sort_value} } },
            {
                -and => [
                    { last_activity_at => $after->{sort_value} },
                    { thread_id        => { q{<} => $after->{id} } },
                ],
            },
        ];
    }

    return $query;
}

sub _user_hash {
    my ($user) = @_;

    return {
        user_id       => _column( $user, 'id' ),
        username      => _column( $user, 'username' ),
        display_name  => _column( $user, 'display_name' ),
        status        => _column( $user, 'status' ),
        trust_level   => _column( $user, 'trust_level' ) || 0,
        created_at    => _column( $user, 'created_at' ),
        updated_at    => _column( $user, 'updated_at' ),
        profile_label => q{@} . ( _column( $user, 'username' ) || q{} ),
    };
}

sub _thread_hash {
    my ($thread) = @_;

    return {
        thread_id        => _column( $thread, 'thread_id' ),
        category_id      => _column( $thread, 'category_id' ),
        author_user_id   => _column( $thread, 'author_user_id' ),
        title            => _column( $thread, 'title' ),
        slug             => _column( $thread, 'slug' ),
        visibility       => _column( $thread, 'visibility' ),
        moderation_state => _column( $thread, 'moderation_state' ),
        last_activity_at => _column( $thread, 'last_activity_at' ),
        created_at       => _column( $thread, 'created_at' ),
    };
}

sub _normalize_username {
    my ($username) = @_;

    my $normalized = defined $username ? lc $username : q{};
    $normalized =~ s/\A \s+//msx;
    $normalized =~ s/\s+ \z//msx;

    return $normalized;
}

sub _column {
    my ( $row, $column ) = @_;

    return                           if !$row;
    return $row->{$column}           if ref $row eq 'HASH';
    return $row->get_column($column) if $row->can('get_column');

    return;
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
