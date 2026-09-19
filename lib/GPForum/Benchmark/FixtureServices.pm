package GPForum::Benchmark::FixtureServices;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

our $VERSION = '0.001';

const my $DEFAULT_THREAD_COUNT => 20;
const my $DEFAULT_POST_COUNT   => 25;
const my $DEFAULT_SEARCH_LIMIT => 10;
const my $DEFAULT_HINT_LIMIT   => 5;

has thread_count => $DEFAULT_THREAD_COUNT;
has post_count   => $DEFAULT_POST_COUNT;

sub collect {
    return {
        generated_at => '2026-05-24T00:00:00Z',
        process      => {
            pid            => $PROCESS_ID,
            uptime_seconds => 0,
        },
        runtime            => { benchmark_fixture => 1 },
        database           => { status            => 'fixture' },
        query_budgets      => {},
        query_budget_drift => {},
        outbox             => {},
    };
}

sub home_page {
    my ($self) = @_;

    return {
        categories     => $self->list_categories,
        latest_threads =>
          $self->list_public_threads( { limit => $self->thread_count } ),
    };
}

sub list_categories {
    return [
        {
            category_id => 'category-1',
            slug        => 'general',
            title       => 'General',
            description => 'General forum',
            visibility  => 'public',
            position    => 1,
        },
        {
            category_id => 'category-2',
            slug        => 'operations',
            title       => 'Operations',
            description => 'Operational forum',
            visibility  => 'public',
            position    => 2,
        },
    ];
}

sub find_category {
    my ( $self, $category_id ) = @_;

    for my $category ( @{ $self->list_categories } ) {
        return $category if $category->{category_id} eq $category_id;
    }

    return;
}

sub list_category_threads {
    my ( $self, $request ) = @_;

    my $limit = $request->{limit} || $self->thread_count;

    return {
        items       => $self->_threads($limit),
        next_cursor => 'thread-cursor',
    };
}

sub list_public_threads {
    my ( $self, $request ) = @_;

    my $limit = $request->{limit} || $self->thread_count;

    return {
        items       => $self->_threads($limit),
        next_cursor => undef,
    };
}

sub find_thread {
    my ( $self, $thread_id ) = @_;

    return if $thread_id ne 'thread-1';

    return $self->_thread(1);
}

sub thread_page {
    my ( $self, $request ) = @_;

    my $thread = $self->find_thread( $request->{thread_id} );
    return { ok => 0, error => 'not_found' } if !$thread;

    return {
        ok     => 1,
        thread => $thread,
        posts  => {
            items       => $self->_posts( $request->{limit} ),
            next_cursor => 'post-cursor',
        },
    };
}

sub search {
    my ( $self, $actor, $query, $options ) = @_;

    my $limit = $options->{limit} || $DEFAULT_SEARCH_LIMIT;

    return [
        map {
            {
                entity_type => 'thread',
                entity_id   => 'thread-' . $_,
                title       => "Benchmark $query $_",
                body        => 'Safe benchmark excerpt',
                visibility  => 'public',
                indexed_at  => '2026-05-24T00:00:00Z',
            }
        } 1 .. $limit
    ];
}

sub autocomplete {
    my ( $self, $actor, $query, $options ) = @_;

    my $limit = $options->{limit} || $DEFAULT_HINT_LIMIT;

    return [
        map {
            {
                entity_type => 'thread',
                entity_id   => 'thread-' . $_,
                title       => "$query suggestion $_",
                visibility  => 'public',
            }
        } 1 .. $limit
    ];
}

sub list_page_for_user {
    return {
        items => [
            {
                user_id            => 'user-1',
                item_type          => 'thread',
                item_id            => 'thread-1',
                created_at         => '2026-05-24T00:00:00Z',
                rank_score         => 1,
                visibility_version => 1,
                permission_version => 1,
            },
        ],
        next_cursor => undef,
    };
}

sub _threads {
    my ( $self, $limit ) = @_;

    return [ map { $self->_thread($_) } 1 .. $limit ];
}

sub _thread {
    my ( $self, $number ) = @_;

    return {
        thread_id        => 'thread-' . $number,
        category_id      => 'category-1',
        author_user_id   => 'user-1',
        title            => 'Benchmark thread ' . $number,
        slug             => 'benchmark-thread-' . $number,
        pinned           => 0,
        visibility       => 'public',
        moderation_state => 'visible',
        locked_at        => undef,
        last_activity_at => '2026-05-24T00:00:00Z',
        created_at       => '2026-05-24T00:00:00Z',
        safe_excerpt     => 'Safe benchmark excerpt',
    };
}

sub _posts {
    my ( $self, $limit ) = @_;

    my $bounded = $limit || $self->post_count;

    return [
        map {
            {
                post_id          => 'post-' . $_,
                thread_id        => 'thread-1',
                author_user_id   => 'user-1',
                position         => $_,
                visibility       => 'public',
                moderation_state => 'visible',
                body             => 'Benchmark post body ' . $_,
            }
        } 1 .. $bounded
    ];
}

1;
