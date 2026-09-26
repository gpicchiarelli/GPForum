# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Identity::ProfileReader;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Keyset;
use GPForum::Infrastructure::Row;
use GPForum::Service::Forum::PageWindow;

our $VERSION = '0.001';

const my $DEFAULT_THREAD_LIMIT  => 10;
const my @THREAD_CURSOR_COLUMNS => qw(last_activity_at thread_id);
const my @REPLY_CURSOR_COLUMNS  => qw(created_at post_id);
const my $TRUST_NEW             => 0;
const my $TRUST_PARTICIPANT     => 1;
const my $TRUST_TRUSTED         => 2;

has page_window => sub { return GPForum::Service::Forum::PageWindow->new; };
has schema      => undef;

sub public_profile ( $self, $username, $options ) {
    my $user = $self->_find_public_user($username);
    return { ok => 0, error => 'not_found' } if !$user;

    my $safe_options = $options || {};
    my $counts       = $self->_contribution_counts($user);
    my $threads      = $self->_recent_public_threads( $user, $safe_options );
    my $replies      = $self->_recent_public_replies( $user, $safe_options );

    return {
        ok      => 1,
        profile => {
            user    => _user_hash($user),
            trust   => $self->_trust_hash($user),
            counts  => $counts,
            threads => $threads,
            replies => $replies,
        },
    };
}

sub _find_public_user ( $self, $username ) {
    my $undefined;

    my $user = $self->schema->resultset('User')
      ->find( { username => _normalize_username($username) } );

    return $undefined if !$user;
    return $undefined if defined _column( $user, 'deleted_at' );
    return $undefined if ( _column( $user, 'status' ) || q{} ) eq 'suspended';

    return $user;
}

sub _trust_hash ( $self, $user ) {
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
        badge         => _trust_badge(
                 _column( $snapshot, 'trust_level' )
              || _column( $user, 'trust_level' )
              || 0
        ),
    };
}

sub _recent_public_threads ( $self, $user, $options ) {
    my $page = $self->page_window->plan($options);
    my @rows =
      _rows( $self->public_threads_resultset( _column( $user, 'id' ), $page ) );
    my $window = $self->page_window->page( \@rows, $page->{limit},
        \@THREAD_CURSOR_COLUMNS );

    return {
        items       => [ map { _thread_hash($_) } @{ $window->{items} } ],
        next_cursor => $window->{next_cursor},
    };
}

# The resultset the profile's thread list executes. Public so the plan tests
# EXPLAIN what actually runs.
sub public_threads_resultset ( $self, $user_id, $page ) {
    return $self->schema->resultset('Thread')->search_rs(
        _thread_query( $user_id, $page->{after} ),
        {
            columns => [
                qw(
                  thread_id category_id author_user_id title slug visibility
                  moderation_state last_activity_at created_at
                )
            ],
            join     => { category => 'space' },
            order_by => [
                { -desc => 'me.last_activity_at' },
                { -desc => 'me.thread_id' }
            ],
            rows => $page->{fetch_rows} || $DEFAULT_THREAD_LIMIT,
        }
    );
}

sub _recent_public_replies ( $self, $user, $options ) {
    my $page   = $self->page_window->plan($options);
    my $query  = _reply_query( _column( $user, 'id' ), $page->{after} );
    my $search = $self->schema->resultset('Post')->search_rs(
        $query,
        {
            columns => [
                qw(
                  post_id thread_id author_user_id position visibility
                  moderation_state created_at
                )
            ],
            join => [ { thread => { category => 'space' } }, 'current_body' ],
            '+select' => [
                'thread.title', 'thread.slug',
                'current_body.body_rendered_safe'
            ],
            '+as'    => [qw(thread_title thread_slug body)],
            order_by =>
              [ { -desc => 'me.created_at' }, { -desc => 'me.post_id' } ],
            rows => $page->{fetch_rows} || $DEFAULT_THREAD_LIMIT,
        }
    );

    my @rows   = _rows($search);
    my $window = $self->page_window->page( \@rows, $page->{limit},
        \@REPLY_CURSOR_COLUMNS );

    return {
        items       => [ map { _reply_hash($_) } @{ $window->{items} } ],
        next_cursor => $window->{next_cursor},
    };
}

sub _contribution_counts ( $self, $user ) {
    my $user_id = _column( $user, 'id' );
    my $threads = _count_search(
        $self->schema->resultset('Thread')->search_rs(
            _thread_query($user_id), { join => { category => 'space' } }
        )
    );
    my $replies = _count_search(
        $self->schema->resultset('Post')->search_rs(
            _reply_query($user_id),
            { join => { thread => { category => 'space' } } }
        )
    );

    return {
        public_threads => $threads,
        public_replies => $replies,
        total_public   => $threads + $replies,
    };
}

# The category and space a profile row sits in must be public and live: a
# public thread in a private category is not public activity (ADR 0102).
sub _public_placement ($category) {
    return {
        "$category.deleted_at" => undef,
        "$category.visibility" => 'public',
        'space.visibility'     => 'public',
    };
}

# A profile is public for every reader (ADR 0102): only public threads in
# public, live categories of public spaces, whoever is looking.
sub _thread_query ( $user_id, $after = undef ) {
    my $query = {
        'me.author_user_id'   => $user_id,
        'me.deleted_at'       => undef,
        'me.moderation_state' => { -in => [ 'visible', 'locked' ] },
        'me.visibility'       => 'public',
        %{ _public_placement('category') },
    };
    if ($after) {
        GPForum::Infrastructure::Keyset->after(
            $query,
            {
                direction => 'desc',
                id        => [ 'me.thread_id',        $after->{id} ],
                sort      => [ 'me.last_activity_at', $after->{sort_value} ],
            }
        );
    }

    return $query;
}

sub _reply_query ( $user_id, $after = undef ) {
    my $query = {
        'me.author_user_id'       => $user_id,
        'me.deleted_at'           => undef,
        'me.moderation_state'     => 'visible',
        'me.visibility'           => 'public',
        'me.position'             => { q{>} => 1 },
        'thread.deleted_at'       => undef,
        'thread.moderation_state' => { -in => [ 'visible', 'locked' ] },
        'thread.visibility'       => 'public',
        %{ _public_placement('category') },
    };
    if ($after) {
        GPForum::Infrastructure::Keyset->after(
            $query,
            {
                direction => 'desc',
                id        => [ 'me.post_id',    $after->{id} ],
                sort      => [ 'me.created_at', $after->{sort_value} ],
            }
        );
    }

    return $query;
}

sub _user_hash ($user) {
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

sub _thread_hash ($thread) {
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

sub _reply_hash ($post) {
    return {
        post_id          => _column( $post, 'post_id' ),
        thread_id        => _column( $post, 'thread_id' ),
        author_user_id   => _column( $post, 'author_user_id' ),
        position         => _column( $post, 'position' ),
        visibility       => _column( $post, 'visibility' ),
        moderation_state => _column( $post, 'moderation_state' ),
        thread_title     => _column( $post, 'thread_title' ),
        thread_slug      => _column( $post, 'thread_slug' ),
        body             => _column( $post, 'body' ),
        created_at       => _column( $post, 'created_at' ),
    };
}

sub _trust_badge ($level) {
    return 'Trusted contributor' if $level >= $TRUST_TRUSTED;
    return 'Participant'         if $level >= $TRUST_PARTICIPANT;
    return 'New contributor'     if $level >= $TRUST_NEW;

    return 'New contributor';
}

sub _normalize_username ($username) {
    my $normalized = defined $username ? lc $username : q{};
    $normalized =~ s/\A \s+//msx;
    $normalized =~ s/\s+ \z//msx;

    return $normalized;
}

sub _column ( $row, $column ) {
    return GPForum::Infrastructure::Row->column( $row, $column );
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

sub _count_search ($search) {
    return $search->count if $search && $search->can('count');

    my @rows = _rows($search);
    return scalar @rows;
}

1;
