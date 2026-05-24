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
const my $REPORT_DETAILS_MAX => 2_000;
const my $REPORT_REASON_MAX  => 80;
const my $AUTOCOMPLETE_LIMIT => 10;
const my $AUTOCOMPLETE_MIN   => 2;
const my $SEARCH_LIMIT       => 20;
const my $SEARCH_MAX_LIMIT   => 50;
const my $TARGET_POST        => 'post';
const my $TARGET_THREAD      => 'thread';
const my $READ_RATE_LIMIT    => 60;
const my $READ_RATE_WINDOW   => 60;
const my $WRITE_RATE_LIMIT   => 20;
const my $REPORT_RATE_LIMIT  => 5;
const my $CHURN_RATE_LIMIT   => 10;
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

    my $thread = _thread_hash( $page->{thread} );
    my $posts  = [ map { _post_hash($_) } @{ $page->{posts}{items} } ];

    my $payload = {
        thread        => $thread,
        posts         => $posts,
        page_metadata =>
          _thread_page_metadata( $self, $thread, $posts->[0] || {} ),
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

sub feed {
    my ($self) = @_;

    my $user_id = _current_user_id($self);
    return _unauthorized($self) if !$user_id;

    my $page = $self->gp_feed_reader->list_page_for_user(
        $user_id,
        {
            limit => $self->param('limit') || $DEFAULT_PAGE_LIMIT,
            after => $self->param('after'),
        }
    );

    my $payload = {
        feed_items  => [ map { _feed_item_hash($_) } @{ $page->{items} } ],
        next_cursor => $page->{next_cursor},
    };

    return _render_payload( $self, 'forum/feed', $payload, $HTTP_OK );
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

sub report_thread {
    my ($self) = @_;

    my $user_id = _write_user_id( $self, 'report.create' );
    return if !$user_id;

    my $thread = _visible_thread($self);
    return if !$thread;

    return _report_response(
        $self,
        _create_report(
            $self,
            {
                reporter_user_id => $user_id,
                target_type      => $TARGET_THREAD,
                target_id        => _column( $thread, 'thread_id' ),
            }
        ),
        _column( $thread, 'thread_id' ),
        undef,
    );
}

sub report_post {
    my ($self) = @_;

    my $user_id = _write_user_id( $self, 'report.create' );
    return if !$user_id;

    my $post =
      $self->gp_post_reader->find_visible_post( $self->param('post_id') );
    return _not_found( $self, 'post not found' ) if !$post;

    my $thread_id = _column( $post, 'thread_id' );
    return _not_found( $self, 'post not found' )
      if !$self->gp_thread_detail_reader->find_thread($thread_id);

    return _report_response(
        $self,
        _create_report(
            $self,
            {
                reporter_user_id => $user_id,
                target_type      => $TARGET_POST,
                target_id        => _column( $post, 'post_id' ),
            }
        ),
        $thread_id,
        _column( $post, 'post_id' ),
    );
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
                source_type  => 'post',
                source_id    => $post_id,
                actor_id     => $actor_id,
                body_source  => $command->{body}{body_source},
                max_mentions => 10,
                thread_id    => $command->{post}{thread_id},
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

sub _create_report {
    my ( $controller, $input ) = @_;

    my $prepared = _report_input( $controller, $input );
    return $prepared if !$prepared->{ok};

    my $report = eval {
        return $controller->gp_report_store->create_report(
            $prepared->{report} );
    };

    if ($EVAL_ERROR) {
        $controller->app->log->error("report create failed: $EVAL_ERROR");
        return { ok => 0, system_error => 1 };
    }

    return { ok => 1, report => $report };
}

sub _report_input {
    my ( $controller, $input ) = @_;

    my $reason  = _trim( $controller->param('reason') );
    my $details = _trim( $controller->param('details') );
    my %errors;

    if ( !length $reason ) {
        $errors{reason} = 'reason is required';
    }
    elsif ( length $reason > $REPORT_REASON_MAX ) {
        $errors{reason} = 'reason is too long';
    }

    if ( length $details > $REPORT_DETAILS_MAX ) {
        $errors{details} = 'details are too long';
    }

    return { ok => 0, errors => \%errors } if %errors;

    return {
        ok     => 1,
        report => {
            reporter_user_id => $input->{reporter_user_id},
            target_type      => $input->{target_type},
            target_id        => $input->{target_id},
            reason           => $reason,
            details          => $details,
        },
    };
}

sub _report_response {
    my ( $controller, $result, $thread_id, $post_id ) = @_;

    return _report_error_response( $controller, $result ) if !$result->{ok};

    if ( _wants_json($controller) ) {
        return _report_json_response( $controller, $result );
    }

    return _report_redirect( $controller, $thread_id, $post_id );
}

sub _report_error_response {
    my ( $controller, $result ) = @_;

    return _system_failure($controller) if $result->{system_error};

    return _bad_request( $controller, $result->{errors} );
}

sub _report_json_response {
    my ( $controller, $result ) = @_;

    return $controller->render(
        json => {
            status => 'reported',
            report => _report_hash( $result->{report} ),
        },
        status => $HTTP_OK,
    );
}

sub _report_redirect {
    my ( $controller, $thread_id, $post_id ) = @_;

    my $url = $controller->url_for( 'thread', thread_id => $thread_id );
    if ($post_id) {
        $url->fragment( 'post-' . $post_id );
    }

    return $controller->redirect_to($url);
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
            $query,
            {
                limit => _bounded_limit(
                    $self->param('limit'),
                    $SEARCH_LIMIT, $SEARCH_MAX_LIMIT
                ),
            },
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

sub search_autocomplete {
    my ($self) = @_;

    my $query = _trim( $self->param('q') || $self->param('prefix') );

    if ( length $query < $AUTOCOMPLETE_MIN ) {
        return $self->render(
            json   => { query => $query, suggestions => [] },
            status => $HTTP_OK,
        );
    }

    return _rate_limited($self)
      if !_read_allowed( $self, 'search.autocomplete' );

    my $rows = eval {
        return $self->gp_search_service->autocomplete(
            { user_id => _current_user_id($self) },
            $query,
            {
                limit => _bounded_limit(
                    $self->param('limit'), $AUTOCOMPLETE_LIMIT,
                    $SEARCH_MAX_LIMIT,
                ),
            },
        );
    };

    if ($EVAL_ERROR) {
        $self->app->log->warn("autocomplete degraded: $EVAL_ERROR");
        return $self->render(
            json => {
                query       => $query,
                status      => 'degraded',
                suggestions => [],
            },
            status => $HTTP_OK,
        );
    }

    return $self->render(
        json => {
            query       => $query,
            suggestions => [ map { _autocomplete_hash($_) } @{$rows} ],
        },
        status => $HTTP_OK,
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
            limit          => _write_limit_for($action),
            window_seconds => $WRITE_RATE_WINDOW,
        }
    );

    return $decision->{ok};
}

sub _write_limit_for {
    my ($action) = @_;

    return $REPORT_RATE_LIMIT if $action eq 'report.create';
    return $CHURN_RATE_LIMIT
      if $action =~
      /\A thread[.](?:bookmark|subscribe|subscription|unsubscribe)/msx;

    return $WRITE_RATE_LIMIT;
}

sub _read_allowed {
    my ( $controller, $action ) = @_;

    my $actor_id =
      _current_user_id($controller) || _request_address($controller);
    my $decision = $controller->gp_rate_limiter->check(
        {
            scope          => 'forum_retrieval',
            actor_id       => $actor_id,
            action         => $action,
            limit          => $READ_RATE_LIMIT,
            window_seconds => $READ_RATE_WINDOW,
        }
    );

    return $decision->{ok};
}

sub _write_user_id {
    my ( $controller, $action ) = @_;

    return if _reject_bad_csrf($controller);

    my $user_id = _current_user_id($controller);
    return if _reject_unauthenticated( $controller, $user_id );
    return if _reject_rate_limited( $controller, $user_id, $action );
    return if _reject_suspended( $controller, $user_id, $action );

    return $user_id;
}

sub _reject_bad_csrf {
    my ($controller) = @_;

    if ( $controller->validation->csrf_protect->has_error('csrf_token') ) {
        _csrf_failure($controller);
        return 1;
    }

    return;
}

sub _reject_unauthenticated {
    my ( $controller, $user_id ) = @_;

    if ( !$user_id ) {
        _unauthorized($controller);
        return 1;
    }

    return;
}

sub _reject_rate_limited {
    my ( $controller, $user_id, $action ) = @_;

    if ( !_allowed( $controller, $user_id, $action ) ) {
        _rate_limited($controller);
        return 1;
    }

    return;
}

sub _reject_suspended {
    my ( $controller, $user_id, $action ) = @_;

    if ( _requires_participation($action)
        && !_can_participate( $controller, $user_id ) )
    {
        _record_security_event(
            $controller,
            'suspended_user_block',
            {
                action => $action,
                status => $HTTP_FORBIDDEN,
            }
        );
        _forbidden( $controller, 'user is suspended' );
        return 1;
    }

    return;
}

sub _requires_participation {
    my ($action) = @_;

    return $action eq 'thread.create' || $action eq 'reply.create' ? 1 : 0;
}

sub _can_participate {
    my ( $controller, $user_id ) = @_;

    my $decision = $controller->gp_suspension_store->can_participate($user_id);
    return $decision->{ok};
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

sub _thread_page_metadata {
    my ( $controller, $thread, $first_post ) = @_;

    return $controller->gp_metadata_builder->thread_metadata(
        $thread,
        {
            safe_text => $first_post->{body} || q{},
        }
    );
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

sub _autocomplete_hash {
    my ($row) = @_;

    return {
        entity_type => _column( $row, 'entity_type' ),
        entity_id   => _column( $row, 'entity_id' ),
        title       => _column( $row, 'title' ),
        visibility  => _column( $row, 'visibility' ),
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

sub _feed_item_hash {
    my ($row) = @_;

    return {
        user_id            => _column( $row, 'user_id' ),
        item_type          => _column( $row, 'item_type' ),
        item_id            => _column( $row, 'item_id' ),
        created_at         => _column( $row, 'created_at' ),
        rank_score         => _column( $row, 'rank_score' ),
        visibility_version => _column( $row, 'visibility_version' ),
        permission_version => _column( $row, 'permission_version' ),
    };
}

sub _report_hash {
    my ($row) = @_;

    return {
        report_id        => _column( $row, 'report_id' ),
        reporter_user_id => _column( $row, 'reporter_user_id' ),
        target_type      => _column( $row, 'target_type' ),
        target_id        => _column( $row, 'target_id' ),
        reason           => _column( $row, 'reason' ),
        status           => _column( $row, 'status' ),
        created_at       => _column( $row, 'created_at' ),
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

sub _request_address {
    my ($controller) = @_;

    return $controller->tx->remote_address || 'anonymous';
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

sub _bounded_limit {
    my ( $value, $default, $maximum ) = @_;

    return $default
      if !defined $value || $value !~ /\A [[:digit:]]+ \z/msx || $value < 1;

    return $maximum if $value > $maximum;

    return $value;
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

    _record_security_event(
        $controller,
        'csrf_failure',
        {
            status => $HTTP_FORBIDDEN,
        }
    );

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

    _record_security_event(
        $controller,
        'auth_denial',
        {
            status => $HTTP_UNAUTHORIZED,
        }
    );

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

    _record_security_event(
        $controller,
        'auth_denial',
        {
            reason => 'forbidden',
            status => $HTTP_FORBIDDEN,
        }
    );

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

    _record_security_event(
        $controller,
        'rate_limit_hit',
        {
            status => $HTTP_TOO_MANY,
        }
    );

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

sub _record_security_event {
    my ( $controller, $event_type, $metadata ) = @_;

    return $controller->gp_security_telemetry->record(
        $event_type,
        {
            %{$metadata}, route => _current_route_name($controller),
        }
    );
}

sub _current_route_name {
    my ($controller) = @_;

    return eval { return $controller->current_route; } || 'unknown';
}

1;
