package GPForum::Controller::Forum;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base 'Mojolicious::Controller';

use GPForum::Web::ErrorPayload;
use GPForum::Web::RequestPreference;

our $VERSION = '0.001';

const my $HTTP_OK            => 200;
const my $HTTP_CREATED       => 201;
const my $HTTP_BAD_REQUEST   => 400;
const my $HTTP_UNAUTHORIZED  => 401;
const my $HTTP_FORBIDDEN     => 403;
const my $HTTP_CONFLICT      => 409;
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
const my $TARGET_USER        => 'user';
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
      $self->gp_forum_view_model->categories_page( categories => $categories );

    return _render_payload(
        {
            cache_options => _public_cache_options(
                $self, 'categories', ['forum:categories']
            ),
            controller => $self,
            payload    => $payload,
            status     => $HTTP_OK,
            template   => 'forum/categories',
        }
    );
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

    my $payload = $self->gp_forum_view_model->category_page(
        category     => $category,
        threads_page => $threads,
    );

    return _render_payload(
        {
            cache_options => _public_cache_options(
                $self, 'category',
                [ 'forum:categories', "forum:category:$category_id" ]
            ),
            controller => $self,
            payload    => $payload,
            status     => $HTTP_OK,
            template   => 'forum/category',
        }
    );
}

sub thread {
    my ($self) = @_;

    my $user_id = _current_user_id($self);
    my $page    = $self->gp_thread_detail_reader->thread_page(
        {
            thread_id => $self->param('thread_id'),
            limit     => $self->param('limit') || $DEFAULT_PAGE_LIMIT,
            after     => $self->param('after'),
        }
    );

    return _not_found( $self, 'thread not found' ) if !$page->{ok};

    my $payload = $self->gp_forum_view_model->thread_page(
        attachments_by_post =>
          _attachments_for_posts( $self, $page->{posts}{items} ),
        engagement => $self->gp_forum_view_model->engagement_summary(
            bookmark_store     => $self->gp_bookmark_store,
            logger             => $self->app->log,
            subscription_store => $self->gp_subscription_store,
            thread             => $page->{thread},
            user_id            => $user_id,
        ),
        metadata_builder => $self->gp_metadata_builder,
        page             => $page,
        reply_command_id => $user_id ? _new_command_id($self) : q{},
        reading          => $self->gp_forum_view_model->reading_summary(
            posts      => $page->{posts}{items},
            read_state => $self->gp_thread_read_state,
            thread_id  => $self->param('thread_id'),
            user_id    => $user_id,
        ),
    );

    return _render_payload(
        {
            cache_options => _public_cache_options(
                $self, 'thread',
                [ 'forum:thread:' . $self->param('thread_id') ]
            ),
            controller => $self,
            payload    => $payload,
            status     => $HTTP_OK,
            template   => 'forum/thread',
        }
    );
}

sub new_thread_form {
    my ($self) = @_;

    my $categories = $self->gp_category_reader->list_categories( {} );

    my $payload = $self->gp_forum_view_model->new_thread_form(
        categories           => $categories,
        command_id           => _new_command_id($self),
        csrf_token           => $self->csrf_token,
        errors               => {},
        selected_category_id => $self->param('category_id') || q{},
        values               => {},
    );

    return _render_payload(
        {
            controller => $self,
            payload    => $payload,
            status     => $HTTP_OK,
            template   => 'forum/new_thread',
        }
    );
}

sub create_thread {
    my ($self) = @_;

    my $user_id = _write_user_id( $self, 'thread.create' );
    return if !$user_id;

    my $result = $self->gp_posting_workflow->create_thread(
        {
            category_id    => $self->param('category_id'),
            author_user_id => $user_id,
            title          => $self->param('title'),
            body_source    => $self->param('body_source'),
            command_id     => _command_id_param($self),
            visibility     => $self->param('visibility'),
        }
    );

    if ( !$result->{ok} ) {
        return _thread_write_failure( $self, $result );
    }

    return _created_thread_response( $self, $result->{stored} );
}

sub create_reply {
    my ($self) = @_;

    my $user_id = _write_user_id( $self, 'reply.create' );
    return if !$user_id;

    my $result = $self->gp_posting_workflow->create_reply(
        {
            thread_id      => $self->param('thread_id'),
            author_user_id => $user_id,
            body_source    => $self->param('body_source'),
            command_id     => _command_id_param($self),
            visibility     => $self->param('visibility'),
        }
    );

    if ( !$result->{ok} ) {
        return _reply_write_failure( $self, $result );
    }

    return _created_post_response( $self, $result->{stored} );
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

    my $payload = $self->gp_community_view_model->feed_page( page => $page );

    return _render_payload(
        {
            controller => $self,
            payload    => $payload,
            status     => $HTTP_OK,
            template   => 'forum/feed',
        }
    );
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

    my $payload =
      $self->gp_community_view_model->bookmarks_page( page => $page );

    return _render_payload(
        {
            controller => $self,
            payload    => $payload,
            status     => $HTTP_OK,
            template   => 'forum/bookmarks',
        }
    );
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

sub report_profile {
    my ($self) = @_;

    my $user_id = _write_user_id( $self, 'report.create' );
    return if !$user_id;

    my $username = $self->param('username');
    my $profile  = $self->gp_profile_reader->public_profile(
        $username,
        {
            limit => 1,
        }
    );

    return _not_found( $self, 'profile not found' ) if !$profile->{ok};

    return _profile_report_response(
        $self,
        _create_report(
            $self,
            {
                reporter_user_id => $user_id,
                target_type      => $TARGET_USER,
                target_id        => $profile->{profile}{user}{user_id},
            }
        ),
        $profile->{profile}{user}{username} || $username,
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

sub _attachments_for_posts {
    my ( $controller, $posts ) = @_;

    return {} if !@{$posts};

    my $by_post = eval {
        return $controller->gp_attachment_store->attachments_for_posts(
            [ map { _column( $_, 'post_id' ) } @{$posts} ],
            { viewer_user_id => _current_user_id($controller) },
        );
    };
    if ($EVAL_ERROR) {
        $controller->app->log->warn("attachment listing degraded: $EVAL_ERROR");
        return {};
    }

    return $by_post || {};
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

sub _profile_report_response {
    my ( $controller, $result, $username ) = @_;

    return _report_error_response( $controller, $result ) if !$result->{ok};

    if ( _wants_json($controller) ) {
        return _report_json_response( $controller, $result );
    }

    return $controller->redirect_to( 'profile', username => $username );
}

sub _report_error_response {
    my ( $controller, $result ) = @_;

    return _system_failure($controller) if $result->{system_error};

    return _bad_request( $controller, $result->{errors} );
}

sub _report_json_response {
    my ( $controller, $result ) = @_;

    return $controller->render(
        json => $controller->gp_forum_view_model->report_response(
            $result->{report},
        ),
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
            json => $controller->gp_forum_view_model->created_thread_response(
                $stored),
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
            json =>
              $controller->gp_forum_view_model->created_post_response($stored),
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
            json =>
              $controller->gp_forum_view_model->read_marker_response($marked),
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
            json => $controller->gp_community_view_model->bookmark_response(
                $status, $bookmark,
            ),
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
            json => $controller->gp_community_view_model->subscription_response(
                $status, $subscription
            ),
            status => $HTTP_OK,
        );
    }

    return $controller->redirect_to( 'thread',
        thread_id => $controller->param('thread_id'), );
}

sub search {
    my ($self) = @_;

    my $query   = _trim( $self->param('q') );
    my $filters = _search_filters($self);
    my $limit =
      _bounded_limit( $self->param('limit'), $SEARCH_LIMIT, $SEARCH_MAX_LIMIT );
    my $fetch_limit = $limit < $SEARCH_MAX_LIMIT ? $limit + 1 : $limit;

    if ( !length $query ) {
        return _render_payload(
            {
                controller => $self,
                payload    => $self->gp_forum_view_model->search_page(
                    filters    => $filters,
                    has_more   => 0,
                    limit      => $limit,
                    more_limit => undef,
                    query      => q{},
                    results    => [],
                ),
                status   => $HTTP_OK,
                template => 'forum/search',
            }
        );
    }

    my $rows = eval {
        return $self->gp_search_service->search(
            { user_id => _current_user_id($self) },
            $query,
            {
                %{$filters}, limit => $fetch_limit,
            },
        );
    };

    if ($EVAL_ERROR) {
        $self->app->log->warn("search degraded: $EVAL_ERROR");
        return _render_payload(
            {
                controller => $self,
                payload    => $self->gp_forum_view_model->search_page(
                    filters    => $filters,
                    has_more   => 0,
                    limit      => $limit,
                    more_limit => undef,
                    query      => $query,
                    results    => [],
                    status     => 'degraded',
                ),
                status   => $HTTP_OK,
                template => 'forum/search',
            }
        );
    }

    my @results  = @{$rows};
    my $has_more = @results > $limit ? 1 : 0;
    pop @results while @results > $limit;
    my $more_limit =
      $has_more
      ? _bounded_limit( $limit * 2, $SEARCH_LIMIT, $SEARCH_MAX_LIMIT )
      : undef;

    return _render_payload(
        {
            controller => $self,
            payload    => $self->gp_forum_view_model->search_page(
                query      => $query,
                filters    => $filters,
                has_more   => $has_more,
                limit      => $limit,
                more_limit => $more_limit,
                results    => \@results,
            ),
            status   => $HTTP_OK,
            template => 'forum/search',
        }
    );
}

sub search_autocomplete {
    my ($self) = @_;

    my $query = _trim( $self->param('q') || $self->param('prefix') );

    if ( length $query < $AUTOCOMPLETE_MIN ) {
        return $self->render(
            json => $self->gp_forum_view_model->autocomplete_response(
                query       => $query,
                suggestions => [],
            ),
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
            json => $self->gp_forum_view_model->autocomplete_response(
                query       => $query,
                status      => 'degraded',
                suggestions => [],
            ),
            status => $HTTP_OK,
        );
    }

    return $self->render(
        json => $self->gp_forum_view_model->autocomplete_response(
            query       => $query,
            suggestions => $rows,
        ),
        status => $HTTP_OK,
    );
}

sub _render_payload {
    my ($input) = @_;

    if ( _wants_json( $input->{controller} ) ) {
        return $input->{controller}->render(
            json   => $input->{payload},
            status => $input->{status},
        );
    }

    if ( $input->{cache_options} ) {
        return $input->{controller}->gp_public_http_cache->render(
            controller => $input->{controller},
            template   => $input->{template},
            payload    => $input->{payload},
            status     => $input->{status},
            %{ $input->{cache_options} },
        );
    }

    return $input->{controller}->render(
        template => $input->{template},
        %{ $input->{payload} },
        status => $input->{status},
    );
}

sub _public_cache_options {
    my ( $controller, $name, $tags ) = @_;

    my $path_query = q{} . $controller->req->url->path_query;

    return {
        key  => join( q{:}, 'forum-ssr', $name, $path_query ),
        tags => [ 'forum:public-html', @{$tags} ],
    };
}

sub _wants_json {
    my ($controller) = @_;

    return GPForum::Web::RequestPreference->wants_json($controller);
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

sub _thread_form_bad_request {
    my ( $controller, $prepared ) = @_;

    return _bad_request( $controller, $prepared->{errors} )
      if _wants_json($controller);

    my $categories = $controller->gp_category_reader->list_categories( {} );
    my $values     = $prepared->{values} || {};
    my $form_state = _thread_form_state( $controller, $values );

    return $controller->render(
        template => 'forum/new_thread',
        status   => $HTTP_BAD_REQUEST,
        %{
            $controller->gp_forum_view_model->new_thread_form(
                categories           => $categories,
                command_id           => $form_state->{command_id},
                csrf_token           => $controller->csrf_token,
                errors               => $prepared->{errors} || {},
                selected_category_id => $form_state->{selected_category_id},
                values               => $values,
            )
        },
    );
}

sub _thread_form_state {
    my ( $controller, $values ) = @_;

    return {
        command_id           => _thread_form_command_id( $controller, $values ),
        selected_category_id =>
          _thread_form_selected_category_id( $controller, $values ),
    };
}

sub _thread_form_command_id {
    my ( $controller, $values ) = @_;

    return $values->{command_id}
      if defined $values->{command_id} && length $values->{command_id};

    return _new_command_id($controller);
}

sub _thread_form_selected_category_id {
    my ( $controller, $values ) = @_;

    return $values->{category_id}
      if defined $values->{category_id} && length $values->{category_id};

    return _trim( $controller->param('category_id') );
}

sub _thread_write_failure {
    my ( $controller, $result ) = @_;

    return _write_failure(
        $controller,
        $result,
        {
            conflict =>
              sub { return _conflict( $controller, $result->{error} ); },
            invalid => sub {
                return _thread_form_bad_request( $controller,
                    $result->{prepared} );
            },
            not_found =>
              sub { return _not_found( $controller, $result->{error} ); },
        }
    );
}

sub _reply_write_failure {
    my ( $controller, $result ) = @_;

    return _write_failure(
        $controller,
        $result,
        {
            conflict =>
              sub { return _conflict( $controller, $result->{error} ); },
            forbidden =>
              sub { return _forbidden( $controller, $result->{error} ); },
            invalid => sub {
                return _bad_request( $controller, $result->{prepared}{errors} );
            },
            not_found =>
              sub { return _not_found( $controller, $result->{error} ); },
        }
    );
}

sub _write_failure {
    my ( $controller, $result, $handlers ) = @_;

    my $status  = $result->{status} || q{};
    my $handler = $handlers->{$status};
    if ($handler) {
        return $handler->();
    }

    return _system_failure($controller);
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

sub _search_filters {
    my ($controller) = @_;

    my %filters;
    for my $field (qw(category_id author_user_id from to)) {
        my $value = _trim( $controller->param($field) );
        $filters{$field} = $value if length $value;
    }

    return \%filters;
}

sub _column {
    my ( $row, $name ) = @_;

    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row && $row->can('get_column');

    my $undefined;
    return $undefined;
}

sub _current_user_id {
    my ($controller) = @_;

    return $controller->session('user_id');
}

sub _new_command_id {
    my ($controller) = @_;

    return $controller->gp_id->uuid;
}

sub _command_id_param {
    my ($controller) = @_;

    my $command_id = _trim( $controller->param('command_id') );
    return $command_id if length $command_id;

    return _trim( $controller->param('idempotency_key') );
}

sub _request_address {
    my ($controller) = @_;

    return $controller->tx->remote_address || 'anonymous';
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
        GPForum::Web::ErrorPayload->bad_request(
            error  => 'The submitted forum request was invalid.',
            errors => $errors,
            title  => 'Invalid request',
        )
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

    return _render_error( $controller, $HTTP_FORBIDDEN,
        GPForum::Web::ErrorPayload->csrf_failure,
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

    return _render_error( $controller, $HTTP_UNAUTHORIZED,
        GPForum::Web::ErrorPayload->unauthorized,
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

    return _render_error( $controller, $HTTP_FORBIDDEN,
        GPForum::Web::ErrorPayload->forbidden( error => $error ),
    );
}

sub _not_found {
    my ( $controller, $error ) = @_;

    return _render_error( $controller, $HTTP_NOT_FOUND,
        GPForum::Web::ErrorPayload->not_found( error => $error ),
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

    return _render_error( $controller, $HTTP_TOO_MANY,
        GPForum::Web::ErrorPayload->rate_limited,
    );
}

sub _conflict {
    my ( $controller, $error ) = @_;

    return _render_error(
        $controller,
        $HTTP_CONFLICT,
        GPForum::Web::ErrorPayload->conflict(
            error => $error || 'idempotency conflict',
            title => 'Conflict',
        )
    );
}

sub _system_failure {
    my ($controller) = @_;

    return _render_error( $controller, $HTTP_SERVER_ERROR,
        GPForum::Web::ErrorPayload->system_failure,
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
