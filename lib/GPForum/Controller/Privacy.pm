package GPForum::Controller::Privacy;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base 'Mojolicious::Controller';

our $VERSION = '0.001';

const my $DEFAULT_LIMIT     => 25;
const my $HTTP_OK           => 200;
const my $HTTP_BAD_REQUEST  => 400;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_NOT_FOUND    => 404;
const my $HTTP_CONFLICT     => 409;
const my $HTTP_SERVER_ERROR => 500;
const my $PRIVACY_RESOURCE  => 'privacy_rights';
const my $ACTION_VIEW       => 'view';
const my $ACTION_MANAGE     => 'manage';

sub dashboard {
    my ($self) = @_;

    my $user_id = _current_user_id($self);
    return _unauthorized($self) if !$user_id;

    my $payload = eval {
        return {
            csrf_token        => $self->csrf_token,
            deletion_requests => [
                map { _deletion_request_hash($_) } @{
                    $self->gp_data_rights_review->deletion_requests_for_user(
                        $user_id, { limit => _limit_param($self) },
                    )
                }
            ],
            export_requests => [
                map { _export_request_hash($_) } @{
                    $self->gp_data_rights_review->export_requests_for_user(
                        $user_id, { limit => _limit_param($self) },
                    )
                }
            ],
            active_holds => [
                map { _retention_hold_hash($_) } @{
                    $self->gp_data_rights_review->active_holds_for_user(
                        $user_id, { limit => _limit_param($self) },
                    )
                }
            ],
        };
    };

    if ($EVAL_ERROR) {
        $self->app->log->error("privacy dashboard failed: $EVAL_ERROR");
        return _system_failure($self);
    }

    return _render_payload( $self, 'privacy/dashboard', $payload, $HTTP_OK );
}

sub request_export {
    my ($self) = @_;

    my $user_id = _write_user_id($self);
    return if !$user_id;

    my $export = eval {
        my $request =
          $self->gp_export_bundle_builder->request_user_export($user_id);
        my $completed =
          $self->gp_export_bundle_builder->complete_user_export(
            $request->{export_request_id} );

        return $completed || $request;
    };

    return _system_failure($self) if $EVAL_ERROR;

    return _privacy_action_response( $self, 'export_requested',
        { export_request => _export_request_hash($export) } );
}

sub request_deletion {
    my ($self) = @_;

    my $user_id = _write_user_id($self);
    return if !$user_id;

    my $reason = _trim( $self->param('reason') );
    return _bad_request( $self, { reason => 'reason is required' } )
      if !length $reason;

    my $request = eval {
        return $self->gp_deletion_workflow->request_deletion(
            {
                requester_user_id => $user_id,
                resource_type     => 'user',
                resource_id       => $user_id,
                request_type      => 'anonymize',
                reason            => $reason,
            }
        );
    };

    return _system_failure($self) if $EVAL_ERROR;

    return _privacy_action_response( $self, 'deletion_requested',
        { deletion_request => _deletion_request_hash($request) } );
}

sub review {
    my ($self) = @_;

    my $user_id = _authorized_user_id( $self, $ACTION_VIEW );
    return if !$user_id;

    my $payload = eval {
        return {
            active_holds => [
                map { _retention_hold_hash($_) } @{
                    $self->gp_data_rights_review->active_holds(
                        { limit => _limit_param($self) },
                    )
                }
            ],
            csrf_token        => $self->csrf_token,
            deletion_requests => [
                map { _deletion_request_hash($_) } @{
                    $self->gp_data_rights_review->pending_deletion_requests(
                        { limit => _limit_param($self) },
                    )
                }
            ],
            erasure_jobs => [
                map { _erasure_job_hash($_) } @{
                    $self->gp_data_rights_review->erasure_jobs_by_status(
                        'pending', { limit => _limit_param($self) },
                    )
                }
            ],
            export_requests => [
                map { _export_request_hash($_) } @{
                    $self->gp_data_rights_review->pending_export_requests(
                        { limit => _limit_param($self) },
                    )
                }
            ],
        };
    };

    if ($EVAL_ERROR) {
        $self->app->log->error("privacy review failed: $EVAL_ERROR");
        return _system_failure($self);
    }

    return _render_payload( $self, 'privacy/review', $payload, $HTTP_OK );
}

sub approve_deletion {
    my ($self) = @_;

    my $actor_id = _authorized_write_user_id($self);
    return if !$actor_id;

    my $reason = _trim( $self->param('reason') );
    return _bad_request( $self, { reason => 'reason is required' } )
      if !length $reason;

    my $approved = eval {
        return $self->gp_deletion_workflow->approve_request(
            $self->param('request_id'),
            $actor_id, $reason, );
    };

    return _system_failure($self)                            if $EVAL_ERROR;
    return _not_found( $self, 'deletion request not found' ) if !$approved;
    return _conflict( $self, $approved->{error} ) if !$approved->{ok};

    return _privacy_action_response( $self, 'deletion_approved',
        { deletion_review => _deletion_review_hash($approved) },
        'privacy_review' );
}

sub hold_deletion {
    my ($self) = @_;

    my $actor_id = _authorized_write_user_id($self);
    return if !$actor_id;

    my $reason = _trim( $self->param('reason') );
    return _bad_request( $self, { reason => 'reason is required' } )
      if !length $reason;

    my $held = eval {
        my $request =
          $self->gp_data_rights_review->deletion_request(
            $self->param('request_id') );
        return if !$request;

        my $hold = $self->gp_retention_hold_store->create_hold(
            {
                created_by    => $actor_id,
                reason        => $reason,
                resource_id   => _column( $request, 'resource_id' ),
                resource_type => _column( $request, 'resource_type' ),
            }
        );

        return $self->gp_deletion_workflow->hold_request(
            $self->param('request_id'),
            $actor_id, $reason, $hold, );
    };

    return _system_failure($self)                            if $EVAL_ERROR;
    return _not_found( $self, 'deletion request not found' ) if !$held;

    return _privacy_action_response( $self, 'deletion_held',
        { deletion_review => _deletion_review_hash($held) },
        'privacy_review' );
}

sub run_erasure_job {
    my ($self) = @_;

    my $actor_id = _authorized_write_user_id($self);
    return if !$actor_id;

    my $result = eval {
        return $self->gp_deletion_workflow->complete_job(
            $self->param('job_id'), $actor_id );
    };

    return _system_failure($self)                       if $EVAL_ERROR;
    return _not_found( $self, 'erasure job not found' ) if !$result;
    return _conflict( $self, $result->{error} )         if !$result->{ok};

    return _privacy_action_response( $self, 'erasure_completed',
        { erasure_job => $result },
        'privacy_review' );
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

    return $user_id;
}

sub _authorized_write_user_id {
    my ($controller) = @_;

    if ( $controller->validation->csrf_protect->has_error('csrf_token') ) {
        _csrf_failure($controller);
        return;
    }

    return _authorized_user_id( $controller, $ACTION_MANAGE );
}

sub _authorized_user_id {
    my ( $controller, $action ) = @_;

    my $user_id = _current_user_id($controller);
    if ( !$user_id ) {
        _unauthorized($controller);
        return;
    }

    my $allowed = $controller->gp_permission_gate->allowed(
        { user_id => $user_id },
        {
            resource_type => $PRIVACY_RESOURCE,
            action        => $action,
        }
    );
    if ( !$allowed ) {
        _forbidden($controller);
        return;
    }

    return $user_id;
}

sub _privacy_action_response {
    my ( $controller, $status, $payload, $redirect_route ) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render(
            json   => { status => $status, %{$payload} },
            status => $HTTP_OK,
        );
    }

    return $controller->redirect_to( $redirect_route || 'privacy_dashboard' );
}

sub _render_payload {
    my ( $controller, $template, $payload, $status ) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render( json => $payload, status => $status );
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
        return $controller->render( json => $payload, status => $status );
    }

    return $controller->render(
        template => 'forum/error',
        %{$payload},
        status => $status,
    );
}

sub _deletion_request_hash {
    my ($row) = @_;

    return {
        completed_at        => _column( $row, 'completed_at' ),
        created_at          => _column( $row, 'created_at' ),
        deletion_request_id => _column( $row, 'deletion_request_id' ),
        reason              => _column( $row, 'reason' ),
        request_type        => _column( $row, 'request_type' ),
        requester_user_id   => _column( $row, 'requester_user_id' ),
        resource_id         => _column( $row, 'resource_id' ),
        resource_type       => _column( $row, 'resource_type' ),
        status              => _column( $row, 'status' ),
    };
}

sub _export_request_hash {
    my ($row) = @_;

    return {
        created_at        => _column( $row, 'created_at' ),
        export_request_id => _column( $row, 'export_request_id' ),
        export_type       => _column( $row, 'export_type' ),
        finished_at       => _column( $row, 'finished_at' ),
        format            => _column( $row, 'format' ),
        manifest          => _column( $row, 'manifest' ) || {},
        requester_user_id => _column( $row, 'requester_user_id' ),
        status            => _column( $row, 'status' ),
        subject_user_id   => _column( $row, 'subject_user_id' ),
    };
}

sub _retention_hold_hash {
    my ($row) = @_;

    return {
        created_at        => _column( $row, 'created_at' ),
        created_by        => _column( $row, 'created_by' ),
        ends_at           => _column( $row, 'ends_at' ),
        reason            => _column( $row, 'reason' ),
        resource_id       => _column( $row, 'resource_id' ),
        resource_type     => _column( $row, 'resource_type' ),
        retention_hold_id => _column( $row, 'retention_hold_id' ),
        starts_at         => _column( $row, 'starts_at' ),
    };
}

sub _erasure_job_hash {
    my ($row) = @_;

    return {
        completed_at        => _column( $row, 'completed_at' ),
        deletion_request_id => _column( $row, 'deletion_request_id' ),
        erasure_job_id      => _column( $row, 'erasure_job_id' ),
        last_error          => _column( $row, 'last_error' ),
        scheduled_at        => _column( $row, 'scheduled_at' ),
        status              => _column( $row, 'status' ),
    };
}

sub _deletion_review_hash {
    my ($result) = @_;

    return {
        error      => $result->{error},
        idempotent => $result->{idempotent} || 0,
        job        => $result->{job},
        ok         => $result->{ok} || 0,
        request_id => $result->{request_id},
    };
}

sub _column {
    my ( $row, $name ) = @_;

    my $undefined;
    return $undefined              if !$row;
    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row && $row->can('get_column');

    return $undefined;
}

sub _current_user_id {
    my ($controller) = @_;

    return $controller->session('user_id');
}

sub _limit_param {
    my ($controller) = @_;

    return $controller->param('limit') || $DEFAULT_LIMIT;
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
            error  => 'The submitted privacy request was invalid.',
            errors => $errors,
            status => 'invalid',
            title  => 'Invalid privacy request',
        }
    );
}

sub _csrf_failure {
    my ($controller) = @_;

    return _render_error(
        $controller,
        $HTTP_FORBIDDEN,
        {
            error  => 'Bad CSRF token',
            status => 'forbidden',
            title  => 'Forbidden',
        }
    );
}

sub _unauthorized {
    my ($controller) = @_;

    return _render_error(
        $controller,
        $HTTP_UNAUTHORIZED,
        {
            error  => 'authentication required',
            status => 'unauthorized',
            title  => 'Authentication required',
        }
    );
}

sub _forbidden {
    my ($controller) = @_;

    return _render_error(
        $controller,
        $HTTP_FORBIDDEN,
        {
            error  => 'permission denied',
            status => 'forbidden',
            title  => 'Forbidden',
        }
    );
}

sub _not_found {
    my ( $controller, $error ) = @_;

    return _render_error(
        $controller,
        $HTTP_NOT_FOUND,
        {
            error  => $error,
            status => 'not_found',
            title  => 'Not found',
        }
    );
}

sub _conflict {
    my ( $controller, $error ) = @_;

    return _render_error(
        $controller,
        $HTTP_CONFLICT,
        {
            error  => $error,
            status => 'blocked',
            title  => 'Privacy action blocked',
        }
    );
}

sub _system_failure {
    my ($controller) = @_;

    return _render_error(
        $controller,
        $HTTP_SERVER_ERROR,
        {
            error  => 'internal error',
            status => 'error',
            title  => 'Internal error',
        }
    );
}

1;
