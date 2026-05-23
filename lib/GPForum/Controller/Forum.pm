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

    return $self->render(
        json => { categories => [ map { _category_hash($_) } @{$categories} ] },
        status => $HTTP_OK,
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

    return $self->render(
        json => {
            category    => _category_hash($category),
            threads     => [ map { _thread_hash($_) } @{ $threads->{items} } ],
            next_cursor => $threads->{next_cursor},
        },
        status => $HTTP_OK,
    );
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

    return $self->render(
        json => {
            thread => _thread_hash( $page->{thread} ),
            posts  => [ map { _post_hash($_) } @{ $page->{posts}{items} } ],
            next_cursor => $page->{posts}{next_cursor},
        },
        status => $HTTP_OK,
    );
}

sub new_thread_form {
    my ($self) = @_;

    my $categories = $self->gp_category_reader->list_categories( {} );

    return $self->render(
        json => {
            csrf_token => $self->csrf_token,
            categories => [ map { _category_hash($_) } @{$categories} ],
            fields     => [qw(category_id title body_source visibility)],
        },
        status => $HTTP_OK,
    );
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

    return $self->render(
        json => {
            status    => 'created',
            thread_id => _column( $stored->{thread}, 'thread_id' ),
        },
        status => $HTTP_CREATED,
    );
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

    return $controller->render(
        json => {
            status  => 'created',
            post_id => _column( $stored->{post}, 'post_id' ),
        },
        status => $HTTP_CREATED,
    );
}

sub search {
    my ($self) = @_;

    my $query = _trim( $self->param('q') );

    return $self->render(
        json   => { query => q{}, results => [] },
        status => $HTTP_OK,
    ) if !length $query;

    my $rows = eval {
        return $self->gp_search_service->search(
            { user_id => _current_user_id($self) },
            $query, { limit => $self->param('limit') || $SEARCH_LIMIT },
        );
    };

    if ($EVAL_ERROR) {
        $self->app->log->warn("search degraded: $EVAL_ERROR");
        return $self->render(
            json   => { query => $query, status => 'degraded', results => [] },
            status => $HTTP_OK,
        );
    }

    return $self->render(
        json => {
            query   => $query,
            results => [ map { _search_hash($_) } @{$rows} ],
        },
        status => $HTTP_OK,
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

sub _bad_request {
    my ( $controller, $errors ) = @_;

    return $controller->render(
        json   => { status => 'invalid', errors => $errors },
        status => $HTTP_BAD_REQUEST,
    );
}

sub _csrf_failure {
    my ($controller) = @_;

    return $controller->render(
        json   => { status => 'forbidden', error => 'Bad CSRF token' },
        status => $HTTP_FORBIDDEN,
    );
}

sub _unauthorized {
    my ($controller) = @_;

    return $controller->render(
        json =>
          { status => 'unauthorized', error => 'authentication required' },
        status => $HTTP_UNAUTHORIZED,
    );
}

sub _forbidden {
    my ( $controller, $error ) = @_;

    return $controller->render(
        json   => { status => 'forbidden', error => $error },
        status => $HTTP_FORBIDDEN,
    );
}

sub _not_found {
    my ( $controller, $error ) = @_;

    return $controller->render(
        json   => { status => 'not_found', error => $error },
        status => $HTTP_NOT_FOUND,
    );
}

sub _rate_limited {
    my ($controller) = @_;

    return $controller->render(
        json   => { status => 'rate_limited', error => 'too many requests' },
        status => $HTTP_TOO_MANY,
    );
}

sub _system_failure {
    my ($controller) = @_;

    return $controller->render(
        json   => { status => 'error', error => 'internal error' },
        status => $HTTP_SERVER_ERROR,
    );
}

1;
