package GPForum::Controller::Notifications;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base 'Mojolicious::Controller';

use GPForum::Web::ErrorPayload;
use GPForum::Web::RequestPreference;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_NOT_FOUND    => 404;
const my $HTTP_TOO_MANY     => 429;
const my $HTTP_SERVER_ERROR => 500;
const my $DEFAULT_LIMIT     => 25;
const my $WRITE_RATE_LIMIT  => 120;
const my $WRITE_RATE_WINDOW => 60;

sub inbox {
    my ($self) = @_;

    my $user_id = _current_user_id($self);
    return _unauthorized($self) if !$user_id;

    my $result = eval {
        my $page = $self->gp_notification_dispatcher->list_page_for_user(
            $user_id,
            {
                limit => $self->param('limit') || $DEFAULT_LIMIT,
                after => $self->param('after'),
            }
        );
        return {
            page         => $page,
            unread_count =>
              $self->gp_notification_dispatcher->unread_count_for_user(
                $user_id),
        };
    };

    return _system_failure($self) if $EVAL_ERROR;

    return _render_payload(
        $self,
        'notifications/inbox',
        $self->gp_notifications_view_model->notifications_page(
            locale       => $self->ui_locale,
            page         => $result->{page},
            renderer     => $self->gp_notification_renderer,
            unread_count => $result->{unread_count},
        ),
        $HTTP_OK
    );
}

sub mark_read {
    my ($self) = @_;

    my $user_id = _write_user_id( $self, 'notification.read' );
    return if !$user_id;

    my $read = eval {
        return $self->gp_notification_dispatcher->mark_read(
            $self->param('notification_id'), $user_id );
    };

    return _system_failure($self)                        if $EVAL_ERROR;
    return _not_found( $self, 'notification not found' ) if !$read->{ok};

    if ( _wants_json($self) ) {
        return $self->render(
            json =>
              $self->gp_notifications_view_model->mark_read_response($read),
            status => $HTTP_OK,
        );
    }

    return $self->redirect_to('notifications');
}

sub mentions {
    my ($self) = @_;

    my $user_id = _current_user_id($self);
    return _unauthorized($self) if !$user_id;

    my $page = eval {
        return $self->gp_mention_reader->list_page_for_recipient(
            $user_id,
            {
                limit => $self->param('limit') || $DEFAULT_LIMIT,
                after => $self->param('after'),
            }
        );
    };

    return _system_failure($self) if $EVAL_ERROR;

    return _render_payload(
        $self,
        'notifications/mentions',
        $self->gp_notifications_view_model->mentions_page(
            locale   => $self->ui_locale,
            page     => $page,
            renderer => $self->gp_notification_renderer,
        ),
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

sub _allowed {
    my ( $controller, $user_id, $action ) = @_;

    my $decision = $controller->gp_rate_limiter->check(
        {
            scope          => 'notification_http',
            actor_id       => $user_id,
            action         => $action,
            limit          => $WRITE_RATE_LIMIT,
            window_seconds => $WRITE_RATE_WINDOW,
        }
    );

    return $decision->{ok};
}

sub _current_user_id {
    my ($controller) = @_;

    return $controller->session('user_id');
}

sub _wants_json {
    my ($controller) = @_;

    return GPForum::Web::RequestPreference->wants_json($controller);
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
