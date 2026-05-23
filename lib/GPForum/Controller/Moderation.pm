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
const my $REPORT_RESOURCE     => 'report';
const my $ACTION_ASSIGN       => 'assign';
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

sub _authorized_write_user_id {
    my ( $controller, $action ) = @_;

    if ( $controller->validation->csrf_protect->has_error('csrf_token') ) {
        _csrf_failure($controller);
        return;
    }

    return _authorized_user_id( $controller, $action );
}

sub _authorized_user_id {
    my ( $controller, $action ) = @_;

    my $user_id = $controller->session('user_id');
    if ( !$user_id ) {
        _unauthorized($controller);
        return;
    }

    my $allowed = $controller->gp_permission_gate->allowed(
        { user_id => $user_id },
        {
            resource_type => $REPORT_RESOURCE,
            action        => $action,
        }
    );

    if ( !$allowed ) {
        _forbidden($controller);
        return;
    }

    return $user_id;
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
