package GPForum::Controller::Forum;

use strict;
use warnings;

use Const::Fast;
use Digest::SHA qw(sha256_hex);
use English     qw(-no_match_vars);
use Mojo::Base 'Mojolicious::Controller';

our $VERSION = '0.001';

const my $HTTP_OK            => 200;
const my $HTTP_CREATED       => 201;
const my $HTTP_BAD_REQUEST   => 400;
const my $HTTP_UNAUTHORIZED  => 401;
const my $HTTP_FORBIDDEN     => 403;
const my $HTTP_NOT_FOUND     => 404;
const my $HTTP_TOO_MANY      => 429;
const my $HTTP_SERVER_ERROR  => 500;
const my $DEFAULT_PAGE_LIMIT => 25;
const my $SEARCH_LIMIT       => 20;
const my $WRITE_RATE_LIMIT   => 20;
const my $WRITE_RATE_WINDOW  => 60;

sub categories {
    my ($self) = @_;

    my $categories =
      $self->gp_category_reader->list_categories(
        { limit => $self->param('limit') } );
    my $payload =
      { categories => [ map { _category_hash($_) } @{$categories} ], };

    return _render_payload( $self, 'forum/categories', $payload, $HTTP_OK );
}

sub category {
    my ($self) = @_;

    my $category_id = $self->param('category_id');
    my $category    = $self->gp_category_reader->find_category($category_id);

    return _not_found( $self, 'category not found' ) if !$category;

    my $threads = $self->gp_thread_reader->list_category_threads(
        {
            category_id => $category_id,
            limit       => $self->param('limit') || $DEFAULT_PAGE_LIMIT,
            after       => $self->param('after'),
        }
    );

    my $payload = {
        category    => _category_hash($category),
        threads     => [ map { _thread_hash($_) } @{ $threads->{items} } ],
        next_cursor => $threads->{next_cursor},
    };

    return _render_payload( $self, 'forum/category', $payload, $HTTP_OK );
}

sub thread {
    my ($self) = @_;

    my $page = $self->gp_thread_detail_reader->thread_page(
        {
            thread_id => $self->param('thread_id'),
            limit     => $self->param('limit') || $DEFAULT_PAGE_LIMIT,
            after     => $self->param('after'),
        }
    );

    return _not_found( $self, 'thread not found' ) if !$page->{ok};

    my $payload = {
        thread      => _thread_hash( $page->{thread} ),
        posts       => [ map { _post_hash($_) } @{ $page->{posts}{items} } ],
        reading     => _reading_summary( $self, $page ),
        engagement  => _engagement_summary( $self, $page->{thread} ),
        next_cursor => $page->{posts}{next_cursor},
    };

    return _render_payload( $self, 'forum/thread', $payload, $HTTP_OK );
}

sub new_thread_form {
    my ($self) = @_;

    my $categories = $self->gp_category_reader->list_categories( {} );

    my $payload = {
        csrf_token => $self->csrf_token,
        categories => [ map { _category_hash($_) } @{$categories} ],
        fields     => [qw(category_id title body_source visibility)],
    };

    return _render_payload( $self, 'forum/new_thread', $payload, $HTTP_OK );
}

sub create_thread {
    my ($self) = @_;

    my $user_id = _write_user_id( $self, 'thread.create' );
    return if !$user_id;

    my $category_id = $self->param('category_id');
    return _not_found( $self, 'category not found' )
      if !$self->gp_category_reader->find_category($category_id);

    my $prepared = $self->gp_thread_composer->prepare(
        {
            category_id     => $category_id,
            author_user_id  => $user_id,
            title           => $self->param('title'),
            body_source     => $self->param('body_source'),
            body_hash       => _body_hash( $self->param('body_source') ),
            visibility      => $self->param('visibility'),
            idempotency_key => $self->param('idempotency_key'),
        }
    );

    return _bad_request( $self, $prepared->{errors} ) if !$prepared->{ok};

    my $stored = _store_thread( $self, $prepared->{command} );

    return _system_failure($self) if !$stored->{ok};

    _record_post_mentions( $self, $stored, $prepared->{command} );

    return _created_thread_response( $self, $stored );
}

sub create_reply {
    my ($self) = @_;

    my $user_id = _write_user_id( $self, 'reply.create' );
    return if !$user_id;

    my $thread = _reply_thread($self);
    return if !$thread;

    my $prepared =
      $self->gp_post_composer->prepare(
        _reply_input( $self, $user_id, $thread ) );

    return _post_creation_response( $self, $prepared );
}

sub mark_thread_read {
    my ($self) = @_;

    my $user_id = _write_user_id( $self, 'thread.read' );
    return if !$user_id;

    my $thread_id = $self->param('thread_id');
    return _not_found( $self, 'thread not found' )
      if !$self->gp_thread_detail_reader->find_thread($thread_id);

    my $position = $self->param('last_read_position');
    return _bad_request(
        $self,
        {
            last_read_position =>
              'last_read_position must be a non-negative integer',
        }
    ) if !_is_non_negative_integer($position);

    my $marked = $self->gp_thread_read_state->mark_thread_read(
        {
            user_id            => $user_id,
            thread_id          => $thread_id,
            last_read_position => $position,
        }
    );

    return _bad_request( $self, $marked->{errors} ) if !$marked->{ok};

    return _read_marker_response( $self, $marked );
}

sub bookmarks {
    my ($self) = @_;

    my $user_id = _current_user_id($self);
    return _unauthorized($self) if !$user_id;

    my $page = $self->gp_bookmark_store->list_page_for_user(
        $user_id,
        {
            target_type => 'thread',
            limit       => $self->param('limit') || $DEFAULT_PAGE_LIMIT,
            after       => $self->param('after'),
        }
    );

    my $payload = {
        bookmarks   => [ map { _bookmark_hash($_) } @{ $page->{items} } ],
        next_cursor => $page->{next_cursor},
    };

    return _render_payload( $self, 'forum/bookmarks', $payload, $HTTP_OK );
}

sub create_thread_bookmark {
    my ($self) = @_;

    my $user_id = _write_user_id( $self, 'thread.bookmark' );
    return if !$user_id;

    return if !_visible_thread($self);

    my $bookmark = eval {
        return $self->gp_bookmark_store->save_bookmark(
            {
                user_id     => $user_id,
                target_type => 'thread',
                target_id   => $self->param('thread_id'),
                note        => $self->param('note'),
            }
        );
    };

    return _system_failure($self) if $EVAL_ERROR;

    return _bookmark_action_response( $self, 'bookmarked', $bookmark );
}

sub remove_thread_bookmark {
    my ($self) = @_;

    my $user_id = _write_user_id( $self, 'thread.bookmark.remove' );
    return if !$user_id;

    return if !_visible_thread($self);

    my $removed = eval {
        return $self->gp_bookmark_store->remove_for_user_target(
            {
                user_id     => $user_id,
                target_type => 'thread',
                target_id   => $self->param('thread_id'),
            }
        );
    };

    return _system_failure($self)                    if $EVAL_ERROR;
    return _not_found( $self, 'bookmark not found' ) if !$removed->{ok};

    return _bookmark_action_response( $self, 'bookmark_removed', $removed );
}

sub subscribe_thread {
    my ($self) = @_;

    my $user_id = _write_user_id( $self, 'thread.subscribe' );
    return if !$user_id;

    return if !_visible_thread($self);

    my $subscription = eval {
        return $self->gp_subscription_store->save_subscription(
            {
                user_id     => $user_id,
                target_type => 'thread',
                target_id   => $self->param('thread_id'),
                preference  => $self->param('preference') || 'all',
            }
        );
    };

    return _system_failure($self) if $EVAL_ERROR;

    return _subscription_action_response( $self, 'subscribed', $subscription );
}

sub mute_thread_subscription {
    my ($self) = @_;

    my $user_id = _write_user_id( $self, 'thread.subscription.mute' );
    return if !$user_id;

    return if !_visible_thread($self);

    my $muted = eval {
        return $self->gp_subscription_store->mute_for_user_target(
            {
                user_id     => $user_id,
                target_type => 'thread',
                target_id   => $self->param('thread_id'),
            }
        );
    };

    return _system_failure($self)                        if $EVAL_ERROR;
    return _not_found( $self, 'subscription not found' ) if !$muted->{ok};

    return _subscription_action_response( $self, 'subscription_muted', $muted );
}

sub unsubscribe_thread {
    my ($self) = @_;

    my $user_id = _write_user_id( $self, 'thread.unsubscribe' );
    return if !$user_id;

    return if !_visible_thread($self);

    my $revoked = eval {
        return $self->gp_subscription_store->revoke_for_user_target(
            {
                user_id     => $user_id,
                target_type => 'thread',
                target_id   => $self->param('thread_id'),
            }
        );
    };

    return _system_failure($self)                        if $EVAL_ERROR;
    return _not_found( $self, 'subscription not found' ) if !$revoked->{ok};

    return _subscription_action_response( $self, 'unsubscribed', $revoked );
}

sub _visible_thread {
    my ($controller) = @_;

    my $thread = $controller->gp_thread_detail_reader->find_thread(
        $controller->param('thread_id') );

    if ( !$thread ) {
        _not_found( $controller, 'thread not found' );
        return;
    }

    return $thread;
}

sub _reply_thread {
    my ($controller) = @_;

    my $thread_id = $controller->param('thread_id');
    my $thread = $controller->gp_thread_detail_reader->find_thread($thread_id);

    if ( !$thread ) {
        _not_found( $controller, 'thread not found' );
        return;
    }

    if ( defined _column( $thread, 'locked_at' ) ) {
        _forbidden( $controller, 'thread is locked' );
        return;
    }

    return $thread;
}

sub _reply_input {
    my ( $controller, $user_id, $thread ) = @_;

    my $thread_id = $controller->param('thread_id');

    return {
        thread_id      => $thread_id,
        author_user_id => $user_id,
        position    => $controller->gp_post_position->next_position($thread_id),
        body_source => $controller->param('body_source'),
        body_hash   => _body_hash( $controller->param('body_source') ),
        visibility  => _reply_visibility( $controller, $thread ),
    };
}

sub _reply_visibility {
    my ( $controller, $thread ) = @_;

    my $requested = $controller->param('visibility');

    return $requested if defined $requested && length $requested;

    return _column( $thread, 'visibility' );
}

sub _post_creation_response {
    my ( $controller, $prepared ) = @_;

    return _bad_request( $controller, $prepared->{errors} ) if !$prepared->{ok};

    my $stored = _store_post( $controller, $prepared->{command} );

    return _system_failure($controller) if !$stored->{ok};

    _record_post_mentions( $controller, $stored, $prepared->{command} );

    return _created_post_response( $controller, $stored );
}

sub _record_post_mentions {
    my ( $controller, $stored, $command ) = @_;

    my $post_id  = _column( $stored->{post}, 'post_id' );
    my $actor_id = _column( $stored->{post}, 'author_user_id' )
      || $command->{post}{author_user_id};

    my $result = eval {
        return $controller->gp_mention_store->record_for_source(
            {
                source_type => 'post',
                source_id   => $post_id,
                actor_id    => $actor_id,
                body_source => $command->{body}{body_source},
                thread_id   => $command->{post}{thread_id},
            }
        );
    };

    if ($EVAL_ERROR) {
        $controller->app->log->warn("mention recording degraded: $EVAL_ERROR");
        return;
    }

    return $result;
}

sub _reading_summary {
    my ( $controller, $page ) = @_;

    my $user_id = _current_user_id($controller);
    return { authenticated => 0 } if !$user_id;

    return $controller->gp_thread_read_state->summary_for_page(
        $user_id,
        $controller->param('thread_id'),
        $page->{posts}{items},
    );
}

sub _engagement_summary {
    my ( $controller, $thread ) = @_;

    my $user_id = _current_user_id($controller);
    return { authenticated => 0 } if !$user_id;

    my $thread_id = _column( $thread, 'thread_id' );
    my $summary   = eval {
        return {
            authenticated => 1,
            bookmark => $controller->gp_bookmark_store->status_for_user_target(
                $user_id, 'thread', $thread_id
            ),
            subscription =>
              $controller->gp_subscription_store->status_for_user_target(
                $user_id, 'thread', $thread_id
              ),
        };
    };

    if ($EVAL_ERROR) {
        $controller->app->log->warn("engagement summary degraded: $EVAL_ERROR");
        return {
            authenticated => 1,
            status        => 'degraded',
            bookmark      => { bookmarked => 0 },
            subscription  => { subscribed => 0, muted => 0 },
        };
    }

    return $summary;
}

sub _created_thread_response {
    my ( $controller, $stored ) = @_;

    my $thread_id = _column( $stored->{thread}, 'thread_id' );

    if ( _wants_json($controller) ) {
        return $controller->render(
            json => {
                status    => 'created',
                thread_id => $thread_id,
            },
            status => $HTTP_CREATED,
        );
    }

    return $controller->redirect_to( 'thread', thread_id => $thread_id );
}

sub _created_post_response {
    my ( $controller, $stored ) = @_;

    my $thread_id = $controller->param('thread_id');
    my $post_id   = _column( $stored->{post}, 'post_id' );

    if ( _wants_json($controller) ) {
        return $controller->render(
            json => {
                status  => 'created',
                post_id => $post_id,
            },
            status => $HTTP_CREATED,
        );
    }

    return $controller->redirect_to(
        $controller->url_for( 'thread', thread_id => $thread_id )
          ->fragment( 'post-' . $post_id ) );
}

sub _read_marker_response {
    my ( $controller, $marked ) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render(
            json => {
                status     => 'ok',
                read_state => $marked->{read_state},
            },
            status => $HTTP_OK,
        );
    }

    return $controller->redirect_to( 'thread',
        thread_id => $marked->{read_state}{thread_id}, );
}

sub _bookmark_action_response {
    my ( $controller, $status, $bookmark ) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render(
            json => {
                status   => $status,
                bookmark => $bookmark,
            },
            status => $HTTP_OK,
        );
    }

    return $controller->redirect_to( 'thread',
        thread_id => $controller->param('thread_id'), );
}

sub _subscription_action_response {
    my ( $controller, $status, $subscription ) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render(
            json => {
                status       => $status,
                subscription => $subscription,
            },
            status => $HTTP_OK,
        );
    }

    return $controller->redirect_to( 'thread',
        thread_id => $controller->param('thread_id'), );
}

sub search {
    my ($self) = @_;

    my $query = _trim( $self->param('q') );

    if ( !length $query ) {
        return _render_payload( $self, 'forum/search',
            { query => q{}, results => [] }, $HTTP_OK );
    }

    my $rows = eval {
        return $self->gp_search_service->search(
            { user_id => _current_user_id($self) },
            $query, { limit => $self->param('limit') || $SEARCH_LIMIT },
        );
    };

    if ($EVAL_ERROR) {
        $self->app->log->warn("search degraded: $EVAL_ERROR");
        return _render_payload( $self, 'forum/search',
            { query => $query, status => 'degraded', results => [] },
            $HTTP_OK );
    }

    return _render_payload(
        $self,
        'forum/search',
        {
            query   => $query,
            results => [ map { _search_hash($_) } @{$rows} ],
        },
        $HTTP_OK
    );
}

sub _render_payload {
    my ( $controller, $template, $payload, $status ) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render(
            json   => $payload,
            status => $status,
        );
    }

    return $controller->render(
        template => $template,
        %{$payload},
        status => $status,
    );
}

sub _wants_json {
    my ($controller) = @_;

    my $format = $controller->param('format') || q{};
    return 1 if $format eq 'json';

    my $accept = $controller->req->headers->accept || q{};
    return $accept =~ m{application/json}msx ? 1 : 0;
}

sub _render_error {
    my ( $controller, $status, $payload ) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render(
            json   => $payload,
            status => $status,
        );
    }

    return $controller->render(
        template => 'forum/error',
        %{$payload},
        status => $status,
    );
}

sub _store_thread {
    my ( $controller, $command ) = @_;

    my $stored =
      eval { return $controller->gp_thread_store->create_thread($command); };

    if ($EVAL_ERROR) {
        $controller->app->log->error("thread create failed: $EVAL_ERROR");
        return { ok => 0 };
    }

    return $stored;
}

sub _store_post {
    my ( $controller, $command ) = @_;

    my $stored =
      eval { return $controller->gp_post_store->create_post($command); };

    if ($EVAL_ERROR) {
        $controller->app->log->error("reply create failed: $EVAL_ERROR");
        return { ok => 0 };
    }

    return $stored;
}

sub _allowed {
    my ( $controller, $user_id, $action ) = @_;

    my $decision = $controller->gp_rate_limiter->check(
        {
            scope          => 'forum_http',
            actor_id       => $user_id,
            action         => $action,
            limit          => $WRITE_RATE_LIMIT,
            window_seconds => $WRITE_RATE_WINDOW,
        }
    );

    return $decision->{ok};
}

sub _write_user_id {
    my ( $controller, $action ) = @_;

    if ( $controller->validation->csrf_protect->has_error('csrf_token') ) {
        _csrf_failure($controller);
        return;
    }

    my $user_id = _current_user_id($controller);
    if ( !$user_id ) {
        _unauthorized($controller);
        return;
    }

    if ( !_allowed( $controller, $user_id, $action ) ) {
        _rate_limited($controller);
        return;
    }

    return $user_id;
}

sub _category_hash {
    my ($row) = @_;

    return {
        category_id => _column( $row, 'category_id' ),
        slug        => _column( $row, 'slug' ),
        title       => _column( $row, 'title' ),
        description => _column( $row, 'description' ),
        visibility  => _column( $row, 'visibility' ),
        position    => _column( $row, 'position' ),
    };
}

sub _thread_hash {
    my ($row) = @_;

    return {
        thread_id        => _column( $row, 'thread_id' ),
        category_id      => _column( $row, 'category_id' ),
        author_user_id   => _column( $row, 'author_user_id' ),
        title            => _column( $row, 'title' ),
        slug             => _column( $row, 'slug' ),
        pinned           => _column( $row, 'pinned' ),
        visibility       => _column( $row, 'visibility' ),
        moderation_state => _column( $row, 'moderation_state' ),
        locked_at        => _column( $row, 'locked_at' ),
        last_activity_at => _column( $row, 'last_activity_at' ),
    };
}

sub _post_hash {
    my ($row) = @_;

    my $body = _related_current_body($row);
    my $body_text =
      $body
      ? _column( $body, 'body_rendered_safe' )
      : _column( $row,  'body' );

    return {
        post_id          => _column( $row, 'post_id' ),
        thread_id        => _column( $row, 'thread_id' ),
        author_user_id   => _column( $row, 'author_user_id' ),
        position         => _column( $row, 'position' ),
        visibility       => _column( $row, 'visibility' ),
        moderation_state => _column( $row, 'moderation_state' ),
        body             => $body_text,
    };
}

sub _search_hash {
    my ($row) = @_;

    return {
        entity_type => _column( $row, 'entity_type' ),
        entity_id   => _column( $row, 'entity_id' ),
        title       => _column( $row, 'title' ),
        body        => _column( $row, 'body' ),
        visibility  => _column( $row, 'visibility' ),
        indexed_at  => _column( $row, 'indexed_at' ),
    };
}

sub _bookmark_hash {
    my ($row) = @_;

    return {
        bookmark_id => _column( $row, 'bookmark_id' ),
        target_type => _column( $row, 'target_type' ),
        target_id   => _column( $row, 'target_id' ),
        note        => _column( $row, 'note' ),
        created_at  => _column( $row, 'created_at' ),
    };
}

sub _related_current_body {
    my ($row) = @_;

    return if !$row || ref $row eq 'HASH' || !$row->can('current_body');

    return $row->current_body;
}

sub _column {
    my ( $row, $name ) = @_;

    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row && $row->can('get_column');

    return;
}

sub _current_user_id {
    my ($controller) = @_;

    return $controller->session('user_id');
}

sub _body_hash {
    my ($body) = @_;

    return sha256_hex( _trim($body) );
}

sub _trim {
    my ($value) = @_;

    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

sub _is_non_negative_integer {
    my ($value) = @_;

    return 0 if !defined $value;

    return $value =~ /\A [[:digit:]]+ \z/msx ? 1 : 0;
}

sub _bad_request {
    my ( $controller, $errors ) = @_;

    return _render_error(
        $controller,
        $HTTP_BAD_REQUEST,
        {
            status => 'invalid',
            title  => 'Invalid request',
            error  => 'The submitted forum request was invalid.',
            errors => $errors,
        }
    );
}

sub _csrf_failure {
    my ($controller) = @_;

    return _render_error(
        $controller,
        $HTTP_FORBIDDEN,
        {
            status => 'forbidden',
            title  => 'Forbidden',
            error  => 'Bad CSRF token',
        }
    );
}

sub _unauthorized {
    my ($controller) = @_;

    return _render_error(
        $controller,
        $HTTP_UNAUTHORIZED,
        {
            status => 'unauthorized',
            title  => 'Authentication required',
            error  => 'authentication required',
        }
    );
}

sub _forbidden {
    my ( $controller, $error ) = @_;

    return _render_error(
        $controller,
        $HTTP_FORBIDDEN,
        {
            status => 'forbidden',
            title  => 'Forbidden',
            error  => $error,
        }
    );
}

sub _not_found {
    my ( $controller, $error ) = @_;

    return _render_error(
        $controller,
        $HTTP_NOT_FOUND,
        {
            status => 'not_found',
            title  => 'Not found',
            error  => $error,
        }
    );
}

sub _rate_limited {
    my ($controller) = @_;

    return _render_error(
        $controller,
        $HTTP_TOO_MANY,
        {
            status => 'rate_limited',
            title  => 'Too many requests',
            error  => 'too many requests',
        }
    );
}

sub _system_failure {
    my ($controller) = @_;

    return _render_error(
        $controller,
        $HTTP_SERVER_ERROR,
        {
            status => 'error',
            title  => 'Internal error',
            error  => 'internal error',
        }
    );
}

1;
