package GPForum::Controller::Attachments;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base 'Mojolicious::Controller';

use GPForum::Web::ErrorPayload;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_CREATED      => 201;
const my $HTTP_BAD_REQUEST  => 400;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_NOT_FOUND    => 404;
const my $HTTP_SERVER_ERROR => 500;
const my $UPLOAD_ACTION     => 'attachment.upload';

sub upload_post {
    my ($self) = @_;

    my $user_id = _write_user_id($self);
    return if !$user_id;

    my $post =
      $self->gp_post_reader->find_visible_post( $self->param('post_id') );
    return _not_found( $self, 'post not found' ) if !$post;
    return _forbidden( $self, 'post author required' )
      if ( _column( $post, 'author_user_id' ) || q{} ) ne $user_id;

    my $result = eval {
        return $self->gp_attachment_upload_pipeline->upload_and_link(
            {
                actor_user_id => $user_id,
                target_id     => _column( $post, 'post_id' ),
                target_type   => 'post',
                upload        => $self->req->upload('attachment'),
            }
        );
    };

    if ($EVAL_ERROR) {
        $self->app->log->error("attachment upload failed: $EVAL_ERROR");
        return _system_failure($self);
    }
    return _bad_request( $self, $result->{errors} ) if !$result->{ok};

    return _upload_response( $self, $result, _column( $post, 'thread_id' ) );
}

sub download {
    my ($self) = @_;

    my $result = eval {
        return $self->gp_attachment_delivery->download(
            {
                attachment_id  => $self->param('attachment_id'),
                viewer_user_id => _current_user_id($self),
            }
        );
    };

    if ($EVAL_ERROR) {
        $self->app->log->error("attachment download failed: $EVAL_ERROR");
        return _system_failure($self);
    }
    return _not_found( $self, 'attachment not found' )
      if !$result->{ok} && $result->{error} eq 'not_found';
    return _forbidden( $self, 'attachment is not available' ) if !$result->{ok};

    $self->res->headers->content_type( $result->{media_type} );
    $self->res->headers->content_disposition( 'attachment; filename="'
          . _safe_filename( $result->{original_filename} )
          . q{"} );

    return $self->render( data => $result->{content}, status => $HTTP_OK );
}

sub _upload_response {
    my ( $controller, $result, $thread_id ) = @_;

    if ( _wants_json($controller) ) {
        my $download_url = $controller->url_for( 'attachment_download',
            attachment_id => _column( $result->{attachment}, 'attachment_id' ),
        )->to_string;

        return $controller->render(
            json => $controller->gp_attachment_view_model->upload_response(
                $result, download_url => $download_url,
            ),
            status => $HTTP_CREATED,
        );
    }

    return $controller->redirect_to(
        $controller->url_for( 'thread', thread_id => $thread_id )
          ->fragment( 'post-' . $controller->param('post_id') ) );
}

sub _write_user_id {
    my ($controller) = @_;

    if ( $controller->validation->csrf_protect->has_error('csrf_token') ) {
        _csrf_failure($controller);
        return;
    }

    my $user_id = _current_user_id($controller);
    if ( !$user_id ) {
        _unauthorized($controller);
        return;
    }

    my $decision = $controller->gp_rate_limiter->check(
        {
            action         => $UPLOAD_ACTION,
            actor_id       => $user_id,
            limit          => 20,
            scope          => 'forum_http',
            window_seconds => 60,
        }
    );
    if ( !$decision->{ok} ) {
        return _render_error(
            $controller,
            429,
            GPForum::Web::ErrorPayload->rate_limited(
                error => 'rate limit exceeded',
                title => 'Rate limited',
            )
        );
    }

    return $user_id;
}

sub _current_user_id {
    my ($controller) = @_;

    return $controller->session('user_id');
}

sub _column {
    my ( $row, $column ) = @_;

    return $row->{$column}           if ref $row eq 'HASH';
    return $row->get_column($column) if $row && $row->can('get_column');

    return;
}

sub _safe_filename {
    my ($filename) = @_;

    $filename = 'attachment' if !defined $filename || !length $filename;
    $filename =~ s/["\r\n]/_/gmsx;

    return $filename;
}

sub _wants_json {
    my ($controller) = @_;

    my $format = $controller->param('format') || q{};
    return 1 if $format eq 'json';

    my $accept = $controller->req->headers->accept || q{};
    return $accept =~ m{application/json}msx ? 1 : 0;
}

sub _bad_request {
    my ( $controller, $errors ) = @_;

    return _render_error(
        $controller,
        $HTTP_BAD_REQUEST,
        GPForum::Web::ErrorPayload->bad_request(
            error  => 'The submitted attachment was invalid.',
            errors => $errors || {},
            title  => 'Invalid attachment',
        )
    );
}

sub _csrf_failure {
    my ($controller) = @_;

    return _render_error( $controller, $HTTP_FORBIDDEN,
        GPForum::Web::ErrorPayload->csrf_failure,
    );
}

sub _unauthorized {
    my ($controller) = @_;

    return _render_error( $controller, $HTTP_UNAUTHORIZED,
        GPForum::Web::ErrorPayload->unauthorized,
    );
}

sub _forbidden {
    my ( $controller, $error ) = @_;

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

sub _system_failure {
    my ($controller) = @_;

    return _render_error( $controller, $HTTP_SERVER_ERROR,
        GPForum::Web::ErrorPayload->system_failure,
    );
}

sub _render_error {
    my ( $controller, $status, $payload ) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render( json => $payload, status => $status );
    }

    return $controller->render(
        template => 'forum/error',
        %{$payload},
        status => $status,
    );
}

1;
