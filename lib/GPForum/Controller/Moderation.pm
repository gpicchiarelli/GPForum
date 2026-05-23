package GPForum::Controller::Moderation;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base 'Mojolicious::Controller';

our $VERSION = '0.001';

const my $DEFAULT_QUEUE_LIMIT => 50;
const my $HTTP_OK             => 200;
const my $HTTP_BAD_REQUEST    => 400;
const my $HTTP_UNAUTHORIZED   => 401;
const my $HTTP_FORBIDDEN      => 403;
const my $HTTP_NOT_FOUND      => 404;
const my $HTTP_SERVER_ERROR   => 500;
const my $MODERATION_RESOURCE => 'moderation_action';
const my $POST_RESOURCE       => 'post';
const my $REPORT_RESOURCE     => 'report';
const my $THREAD_RESOURCE     => 'thread';
const my $ACTION_ASSIGN       => 'assign';
const my $ACTION_MODERATE     => 'moderate';
const my $ACTION_REVERSE      => 'reverse';
const my $ACTION_RESOLVE      => 'resolve';
const my $ACTION_VIEW_QUEUE   => 'view_queue';

sub reports {
    my ($self) = @_;

    my $user_id = _authorized_user_id( $self, $ACTION_VIEW_QUEUE );
    return if !$user_id;

    my $status = _status_param($self);
    my $rows   = eval {
        return $self->gp_report_store->list_queue(
            {
                status => $status,
                limit  => $self->param('limit') || $DEFAULT_QUEUE_LIMIT,
            }
        );
    };

    if ($EVAL_ERROR) {
        $self->app->log->error("moderation report queue failed: $EVAL_ERROR");
        return _system_failure($self);
    }

    return _render_payload(
        $self,
        'moderation/reports',
        {
            csrf_token => $self->csrf_token,
            reports    => [ map { _report_hash($_) } @{$rows} ],
            status     => $status,
        },
        $HTTP_OK,
    );
}

sub assign_report {
    my ($self) = @_;

    my $user_id = _authorized_write_user_id( $self, $ACTION_ASSIGN );
    return if !$user_id;

    my $assigned = eval {
        return $self->gp_report_store->assign_report( $self->param('report_id'),
            $user_id );
    };

    return _system_failure($self)                  if $EVAL_ERROR;
    return _not_found( $self, 'report not found' ) if !$assigned;

    return _action_response( $self, 'assigned', $assigned );
}

sub resolve_report {
    my ($self) = @_;

    my $user_id = _authorized_write_user_id( $self, $ACTION_RESOLVE );
    return if !$user_id;

    my $resolution = _trim( $self->param('resolution') );
    return _bad_request( $self, { resolution => 'resolution is required' } )
      if !length $resolution;

    my $resolved = eval {
        return $self->gp_report_store->resolve_report(
            $self->param('report_id'),
            $resolution, $user_id );
    };

    return _system_failure($self)                  if $EVAL_ERROR;
    return _not_found( $self, 'report not found' ) if !$resolved;

    return _action_response( $self, 'resolved', $resolved );
}

sub hide_post {
    my ($self) = @_;

    my $user_id =
      _authorized_write_user_id( $self, $POST_RESOURCE, $ACTION_MODERATE );
    return if !$user_id;

    my $reason = _reason_param($self);
    return _bad_request( $self, { reason => 'reason is required' } )
      if !length $reason;

    my $action = eval {
        return $self->gp_moderation_action_store->hide_post(
            {
                actor_user_id => $user_id,
                post_id       => $self->param('post_id'),
                reason        => $reason,
            }
        );
    };

    return _system_failure($self)                if $EVAL_ERROR;
    return _not_found( $self, 'post not found' ) if !$action;

    return _moderation_action_response( $self, 'post_hidden', $action );
}

sub restore_post {
    my ($self) = @_;

    my $user_id =
      _authorized_write_user_id( $self, $POST_RESOURCE, $ACTION_MODERATE );
    return if !$user_id;

    my $reason = _reason_param($self);
    return _bad_request( $self, { reason => 'reason is required' } )
      if !length $reason;

    my $action = eval {
        return $self->gp_moderation_action_store->restore_post(
            {
                actor_user_id => $user_id,
                post_id       => $self->param('post_id'),
                reason        => $reason,
            }
        );
    };

    return _system_failure($self)                if $EVAL_ERROR;
    return _not_found( $self, 'post not found' ) if !$action;

    return _moderation_action_response( $self, 'post_restored', $action );
}

sub lock_thread {
    my ($self) = @_;

    my $user_id =
      _authorized_write_user_id( $self, $THREAD_RESOURCE, $ACTION_MODERATE );
    return if !$user_id;

    my $reason = _reason_param($self);
    return _bad_request( $self, { reason => 'reason is required' } )
      if !length $reason;

    my $action = eval {
        return $self->gp_moderation_action_store->lock_thread(
            {
                actor_user_id => $user_id,
                thread_id     => $self->param('thread_id'),
                reason        => $reason,
            }
        );
    };

    return _system_failure($self)                  if $EVAL_ERROR;
    return _not_found( $self, 'thread not found' ) if !$action;

    return _moderation_action_response( $self, 'thread_locked', $action );
}

sub unlock_thread {
    my ($self) = @_;

    my $user_id =
      _authorized_write_user_id( $self, $THREAD_RESOURCE, $ACTION_MODERATE );
    return if !$user_id;

    my $reason = _reason_param($self);
    return _bad_request( $self, { reason => 'reason is required' } )
      if !length $reason;

    my $action = eval {
        return $self->gp_moderation_action_store->unlock_thread(
            {
                actor_user_id => $user_id,
                thread_id     => $self->param('thread_id'),
                reason        => $reason,
            }
        );
    };

    return _system_failure($self)                  if $EVAL_ERROR;
    return _not_found( $self, 'thread not found' ) if !$action;

    return _moderation_action_response( $self, 'thread_unlocked', $action );
}

sub reverse_action {
    my ($self) = @_;

    my $user_id =
      _authorized_write_user_id( $self, $MODERATION_RESOURCE, $ACTION_REVERSE );
    return if !$user_id;

    my $reversed = eval {
        return $self->gp_moderation_action_store->reverse_action(
            $self->param('action_id'), $user_id );
    };

    return _system_failure($self)                             if $EVAL_ERROR;
    return _not_found( $self, 'moderation action not found' ) if !$reversed;

    return _moderation_action_response( $self, 'action_reversed', $reversed );
}

sub _authorized_write_user_id {
    my ( $controller, $resource_type, $action ) = @_;

    if ( !defined $action ) {
        $action        = $resource_type;
        $resource_type = $REPORT_RESOURCE;
    }

    if ( $controller->validation->csrf_protect->has_error('csrf_token') ) {
        _csrf_failure($controller);
        return;
    }

    return _authorized_user_id( $controller, $resource_type, $action );
}

sub _authorized_user_id {
    my ( $controller, $resource_type, $action ) = @_;

    if ( !defined $action ) {
        $action        = $resource_type;
        $resource_type = $REPORT_RESOURCE;
    }

    my $user_id = $controller->session('user_id');
    if ( !$user_id ) {
        _unauthorized($controller);
        return;
    }

    my $allowed = $controller->gp_permission_gate->allowed(
        { user_id => $user_id },
        {
            resource_type => $resource_type,
            action        => $action,
        }
    );

    if ( !$allowed ) {
        _forbidden($controller);
        return;
    }

    return $user_id;
}

sub _moderation_action_response {
    my ( $controller, $status, $action ) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render(
            json => {
                status => $status,
                action => _moderation_action_hash($action),
            },
            status => $HTTP_OK,
        );
    }

    return $controller->redirect_to('moderation_reports');
}

sub _action_response {
    my ( $controller, $status, $report ) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render(
            json => {
                status => $status,
                report => _report_hash($report),
            },
            status => $HTTP_OK,
        );
    }

    return $controller->redirect_to('moderation_reports');
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

sub _moderation_action_hash {
    my ($result) = @_;

    my $action =
      ref $result eq 'HASH' && exists $result->{action}
      ? $result->{action}
      : $result;

    return {
        moderation_action_id => _column( $action, 'moderation_action_id' ),
        action_type          => _column( $action, 'action_type' ),
        target_type          => _column( $action, 'target_type' ),
        target_id            => _column( $action, 'target_id' ),
        reason               => _column( $action, 'reason' ),
        reversed_at          => _column( $action, 'reversed_at' ),
        reversed_by_user_id  => _column( $action, 'reversed_by_user_id' ),
    };
}

sub _report_hash {
    my ($row) = @_;

    return {
        assigned_moderator_user_id =>
          _column( $row, 'assigned_moderator_user_id' ),
        created_at       => _column( $row, 'created_at' ),
        reason           => _column( $row, 'reason' ),
        report_id        => _column( $row, 'report_id' ),
        reporter_user_id => _column( $row, 'reporter_user_id' ),
        resolution       => _column( $row, 'resolution' ),
        resolved_at      => _column( $row, 'resolved_at' ),
        status           => _column( $row, 'status' ),
        target_id        => _column( $row, 'target_id' ),
        target_type      => _column( $row, 'target_type' ),
    };
}

sub _column {
    my ( $row, $name ) = @_;

    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row && $row->can('get_column');

    return;
}

sub _status_param {
    my ($controller) = @_;

    my $status = _trim( $controller->param('status') );
    return length $status ? $status : 'open';
}

sub _reason_param {
    my ($controller) = @_;

    return _trim( $controller->param('reason') );
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
        {
            status => 'invalid',
            title  => 'Invalid moderation request',
            error  => 'The submitted moderation request was invalid.',
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
    my ($controller) = @_;

    return _render_error(
        $controller,
        $HTTP_FORBIDDEN,
        {
            status => 'forbidden',
            title  => 'Forbidden',
            error  => 'permission denied',
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
