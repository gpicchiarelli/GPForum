package GPForum::Controller::Notifications;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base 'Mojolicious::Controller';

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_TOO_MANY     => 429;
const my $HTTP_SERVER_ERROR => 500;
const my $DEFAULT_LIMIT     => 25;
const my $WRITE_RATE_LIMIT  => 120;
const my $WRITE_RATE_WINDOW => 60;

sub inbox {
    my ($self) = @_;

    my $user_id = _current_user_id($self);
    return _unauthorized($self) if !$user_id;

    my $page = eval {
        return $self->gp_notification_dispatcher->list_page_for_user(
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
        'notifications/inbox',
        {
            notifications =>
              [ map { _notification_hash($_) } @{ $page->{items} } ],
            next_cursor => $page->{next_cursor},
        },
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

    return _system_failure($self) if $EVAL_ERROR;

    if ( _wants_json($self) ) {
        return $self->render(
            json => {
                status => 'read',
                read   => $read,
            },
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
        {
            mentions    => [ map { _mention_hash($_) } @{ $page->{items} } ],
            next_cursor => $page->{next_cursor},
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

sub _notification_hash {
    my ($row) = @_;

    my $notification = _related_notification($row);

    return {
        notification_id   => _column( $row,          'notification_id' ),
        recipient_user_id => _column( $row,          'recipient_user_id' ),
        created_at        => _column( $row,          'created_at' ),
        read_at           => _column( $row,          'read_at' ),
        rank_score        => _column( $row,          'rank_score' ),
        source_type       => _column( $notification, 'source_type' ),
        source_id         => _column( $notification, 'source_id' ),
        notification_type => _column( $notification, 'notification_type' ),
        payload           => _column( $notification, 'payload' ) || {},
    };
}

sub _mention_hash {
    my ($row) = @_;

    return {
        mention_id         => _column( $row, 'mention_id' ),
        source_type        => _column( $row, 'source_type' ),
        source_id          => _column( $row, 'source_id' ),
        actor_id           => _column( $row, 'actor_id' ),
        mentioned_user_id  => _column( $row, 'mentioned_user_id' ),
        mentioned_username => _column( $row, 'mentioned_username' ),
        created_at         => _column( $row, 'created_at' ),
    };
}

sub _related_notification {
    my ($row) = @_;

    return $row if _hash_includes_notification($row);
    return      if _cannot_load_notification($row);

    return $row->notification;
}

sub _hash_includes_notification {
    my ($row) = @_;

    return ref $row eq 'HASH' && exists $row->{notification_type};
}

sub _cannot_load_notification {
    my ($row) = @_;

    return 1 if !$row;
    return 1 if ref $row eq 'HASH';
    return 1 if !$row->can('notification');

    return 0;
}

sub _column {
    my ( $row, $column ) = @_;

    return $row->{$column}           if ref $row eq 'HASH';
    return $row->get_column($column) if $row && $row->can('get_column');

    return;
}

sub _current_user_id {
    my ($controller) = @_;

    return $controller->session('user_id');
}

sub _wants_json {
    my ($controller) = @_;

    my $format = $controller->param('format') || q{};
    return 1 if $format eq 'json';

    my $accept = $controller->req->headers->accept || q{};
    return $accept =~ m{application/json}msx ? 1 : 0;
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

1;
