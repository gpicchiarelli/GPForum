package GPForum::Service::Privacy::Workflow;

use strict;
use warnings;

use English qw(-no_match_vars);
use Mojo::Base -base;

our $VERSION = '0.001';

has deletion_workflow => undef;
has export_builder    => undef;
has hold_store        => undef;
has logger            => undef;
has reviewer          => undef;

sub request_export {
    my ( $self, $input ) = @_;

    return $self->_run_store(
        'export request not found',
        sub { return $self->_complete_export( $input->{user_id} ); },
    );
}

sub request_deletion {
    my ( $self, $input ) = @_;

    my $command = {
        reason            => _trim( $input->{reason} ),
        request_type      => 'anonymize',
        requester_user_id => $input->{user_id},
        resource_id       => $input->{user_id},
        resource_type     => 'user',
    };
    my $invalid = $self->_missing_field( $command, 'reason' );
    if ($invalid) {
        return $invalid;
    }

    return $self->_run_store(
        'deletion request not found',
        sub { return $self->deletion_workflow->request_deletion($command); },
    );
}

sub approve_deletion {
    my ( $self, $input ) = @_;

    my $command = {
        actor_user_id => $input->{actor_user_id},
        reason        => _trim( $input->{reason} ),
        request_id    => $input->{request_id},
    };
    my $invalid = $self->_missing_field( $command, 'reason' );
    if ($invalid) {
        return $invalid;
    }

    return $self->_approve_once($command);
}

sub hold_deletion {
    my ( $self, $input ) = @_;

    my $command = {
        actor_user_id => $input->{actor_user_id},
        reason        => _trim( $input->{reason} ),
        request_id    => $input->{request_id},
    };
    my $invalid = $self->_missing_field( $command, 'reason' );
    if ($invalid) {
        return $invalid;
    }

    return $self->_hold_once($command);
}

sub run_erasure_job {
    my ( $self, $input ) = @_;

    return $self->_run_store(
        'erasure job not found',
        sub {
            return $self->deletion_workflow->complete_job( $input->{job_id},
                $input->{actor_user_id} );
        },
    );
}

sub _approve_once {
    my ( $self, $command ) = @_;

    return $self->_run_store(
        'deletion request not found',
        sub {
            return $self->deletion_workflow->approve_request(
                $command->{request_id},
                $command->{actor_user_id},
                $command->{reason},
            );
        },
    );
}

sub _hold_once {
    my ( $self, $command ) = @_;

    return $self->_run_store(
        'deletion request not found',
        sub { return $self->_create_hold($command); },
    );
}

sub _create_hold {
    my ( $self, $command ) = @_;

    my $request = $self->reviewer->deletion_request( $command->{request_id} );
    if ( !$request ) {
        return;
    }

    my $hold = $self->hold_store->create_hold(
        {
            created_by    => $command->{actor_user_id},
            reason        => $command->{reason},
            resource_id   => _column( $request, 'resource_id' ),
            resource_type => _column( $request, 'resource_type' ),
        }
    );

    return $self->deletion_workflow->hold_request(
        $command->{request_id},
        $command->{actor_user_id},
        $command->{reason}, $hold,
    );
}

sub _complete_export {
    my ( $self, $user_id ) = @_;

    my $request = $self->export_builder->request_user_export($user_id);
    my $completed =
      $self->export_builder->complete_user_export(
        $request->{export_request_id} );
    if ($completed) {
        return $completed;
    }

    return $request;
}

sub _missing_field {
    my ( undef, $input, $name ) = @_;

    if ( length _trim( $input->{$name} ) ) {
        return;
    }

    return _result(
        errors => { $name => "$name is required" },
        status => 'invalid',
    );
}

sub _run_store {
    my ( $self, $not_found, $code ) = @_;

    my $stored = $self->_eval_store($code);
    if ( $stored->{failed} ) {
        return _result(
            error  => 'privacy store failed',
            status => 'failed',
        );
    }

    return _stored_result( $not_found, $stored->{value} );
}

sub _eval_store {
    my ( $self, $code ) = @_;

    my $value = eval { return $code->(); };
    if ($EVAL_ERROR) {
        $self->_log_error("privacy write failed: $EVAL_ERROR");
        return { failed => 1 };
    }

    return { value => $value };
}

sub _stored_result {
    my ( $not_found, $value ) = @_;

    if ( !$value ) {
        return _result(
            error  => $not_found,
            status => 'not_found',
        );
    }

    return _blocked_or_ok($value);
}

sub _blocked_or_ok {
    my ($value) = @_;

    if ( _is_blocked($value) ) {
        return _result(
            error  => $value->{error},
            status => 'conflict',
            stored => $value,
        );
    }

    return _result(
        status => 'ok',
        stored => $value,
    );
}

sub _is_blocked {
    my ($value) = @_;

    if ( ref $value ne 'HASH' ) {
        return 0;
    }
    if ( !exists $value->{ok} ) {
        return 0;
    }

    return $value->{ok} ? 0 : 1;
}

sub _column {
    my ( $row, $name ) = @_;

    if ( !$row ) {
        return;
    }
    if ( ref $row eq 'HASH' ) {
        return $row->{$name};
    }

    return _object_column( $row, $name );
}

sub _object_column {
    my ( $row, $name ) = @_;

    if ( $row->can('get_column') ) {
        return $row->get_column($name);
    }

    return;
}

sub _result {
    my (%input) = @_;

    return {
        error  => $input{error},
        errors => $input{errors},
        ok     => ( $input{status} || q{} ) eq 'ok' ? 1 : 0,
        status => $input{status} || 'failed',
        stored => $input{stored},
    };
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

sub _log_error {
    my ( $self, $message ) = @_;

    if ( !$self->logger || !$self->logger->can('error') ) {
        return;
    }

    $self->logger->error($message);

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Privacy::Workflow - Privacy export, deletion, and hold writes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $result = $workflow->request_deletion(
        {
            reason  => $reason,
            user_id => $user_id,
        }
    );

=head1 DESCRIPTION

Application boundary for member export/deletion requests and staff approval,
legal-hold, and erasure commands. Validates required fields, orchestrates
existing privacy stores, and returns a normalized result hash. Stores keep
transaction, event, audit, and outbox ownership.

=head1 SUBROUTINES/METHODS

=head2 request_export

Creates and completes a user export bundle.

=head2 request_deletion

Creates an anonymize deletion request when a reason is present.

=head2 approve_deletion

Approves a pending deletion request or reports an active hold as conflict.

=head2 hold_deletion

Creates a retention hold and marks the deletion request held.

=head2 run_erasure_job

Completes an erasure job or reports an active hold as conflict.

=head1 DIAGNOSTICS

Returns C<invalid>, C<not_found>, C<conflict>, or C<failed> statuses instead of
throwing for expected write outcomes. Unexpected store exceptions are logged
and mapped to C<failed>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses deletion, export, hold, and review services supplied by the composition
root.

=head1 DEPENDENCIES

Uses L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Command-id replay is not required; deletion stores keep their existing
idempotency for approval and job completion.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
