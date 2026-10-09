# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Privacy::Workflow;

use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Service::Privacy::ErasedExports;

our $VERSION = '0.001';

has command_idempotency => undef;    # optional: writes run unlogged without one
__PACKAGE__->requires(qw(deletion_workflow export_builder hold_store reviewer));
has logger => undef;                 # optional: errors are dropped without one

# Orders an export against the member's erasure; none for an export store
# without a schema.
has erased_exports => sub {
    my ($self) = @_;
    my $builder = $self->export_builder;
    if ( !$builder || !$builder->can('schema') || !$builder->schema ) {
        return undef;
    }

    return GPForum::Service::Privacy::ErasedExports->new(
        schema => $builder->schema );
};

sub request_export ( $self, $input ) {
    my $invalid = $self->_missing_field( $input, 'command_id' );
    if ($invalid) {
        return $invalid;
    }

    my $run = sub {
        return $self->_run_store( 'export request not found',
            sub { return $self->_complete_export( $input->{user_id} ); } );
    };
    if ( !$self->command_idempotency ) {
        return $run->();
    }

    my $result;
    try {
        $result = $self->command_idempotency->result_of(
            {
                actor_id     => $input->{user_id},
                command_id   => $input->{command_id},
                command_type => 'privacy.export',
                request      => { user_id => $input->{user_id} },
                run          => $run,
            }
        );
    }
    catch ($error) {
        $self->_log_error("privacy command log failed: $error");
        return _result(
            error  => 'privacy store failed',
            status => 'failed',
        );
    };

    return $result;
}

sub request_deletion ( $self, $input ) {
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

    return $self->_commanded_store(
        $input,
        'deletion request not found',
        sub { return $self->deletion_workflow->request_deletion($command); },
    );
}

sub approve_deletion ( $self, $input ) {
    my $command = {
        actor_user_id => $input->{actor_user_id},
        reason        => _trim( $input->{reason} ),
        request_id    => $input->{request_id},
    };
    my $invalid = $self->_missing_field( $command, 'reason' );
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_store(
        $input,
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

# A hold on the request's resource, then the request held under it.
sub hold_deletion ( $self, $input ) {
    my $command = {
        actor_user_id => $input->{actor_user_id},
        reason        => _trim( $input->{reason} ),
        request_id    => $input->{request_id},
    };
    my $invalid = $self->_missing_field( $command, 'reason' );
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_store(
        $input,
        'deletion request not found',
        sub {
            my $request =
              $self->reviewer->deletion_request( $command->{request_id} );
            if ( !$request ) {
                return undef;
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
        },
    );
}

sub run_erasure_job ( $self, $input ) {
    return $self->_commanded_store(
        $input,
        'erasure job not found',
        sub {
            return $self->deletion_workflow->complete_job( $input->{job_id},
                $input->{actor_user_id} );
        },
    );
}

# The member's account row is held for share from before the request until
# the export commits, so an erasure either waits for the export and then
# discards it, or has committed and the export finds the member erased.
sub _complete_export ( $self, $user_id ) {
    my $guard = $self->erased_exports;
    if ( !$guard ) {
        return $self->_build_export($user_id);
    }

    return $guard->schema->txn_do(
        sub {
            if ( !$guard->may_export($user_id) ) {
                return undef;
            }

            return $self->_build_export($user_id);
        }
    );
}

sub _build_export ( $self, $user_id ) {
    my $request = $self->export_builder->request_user_export($user_id);
    my $completed =
      $self->export_builder->complete_user_export(
        $request->{export_request_id} );
    if ($completed) {
        return $completed;
    }

    return $request;
}

sub _missing_field ( $, $input, $name ) {
    if ( length _trim( $input->{$name} ) ) {
        return undef;
    }

    return _result(
        errors => { $name => "$name is required" },
        status => 'invalid',
    );
}

sub _commanded_store ( $self, $input, $not_found, $code ) {
    my $invalid = $self->_missing_field( $input, 'command_id' );
    if ($invalid) {
        return $invalid;
    }

    return $self->_run_store( $not_found, $code );
}

# A store that dies fails the write and is logged; one that answers nothing
# is not found; one that answers ok => 0 was blocked, a conflict.
sub _run_store ( $self, $not_found, $code ) {
    my $value;
    try {
        $value = $code->();
    }
    catch ($error) {
        $self->_log_error("privacy write failed: $error");
        return _result(
            error  => 'privacy store failed',
            status => 'failed',
        );
    };
    if ( !$value ) {
        return _result(
            error  => $not_found,
            status => 'not_found',
        );
    }
    if ( ref $value eq 'HASH' && exists $value->{ok} && !$value->{ok} ) {
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

sub _column ( $row, $name ) {
    if ( ref $row eq 'HASH' ) {
        return $row->{$name};
    }
    if ( $row && $row->can('get_column') ) {
        return $row->get_column($name);
    }

    return undef;
}

sub _result (%input) {
    return {
        error  => $input{error},
        errors => $input{errors},
        ok     => ( $input{status} || q{} ) eq 'ok' ? 1 : 0,
        status => $input{status} || 'failed',
        stored => $input{stored},
    };
}

sub _trim ($value) {
    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

sub _log_error ( $self, $message ) {
    if ( !$self->logger ) {
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

Creates and completes a user export bundle when a command id is present.
When the export store has a schema, the export first holds the member's
account row through L<GPForum::Service::Privacy::ErasedExports/may_export>
for the rest of its transaction, so an erasure running at the same time
either waits for it and discards the bundle or has committed already; an
erased or unknown member gets C<not_found> and no export.

=head2 request_deletion

Creates an anonymize deletion request when a command id and reason are present.
An open request for the same resource is reused.

=head2 approve_deletion

Approves a pending deletion request or reports an active hold as conflict when
a command id and reason are present.

=head2 hold_deletion

Creates a retention hold and marks the deletion request held when a command id
and reason are present. C<hold_request> stays four arguments besides the
invocant.

=head2 run_erasure_job

Completes an erasure job or reports an active hold as conflict when a command
id is present.

=head1 DIAGNOSTICS

Returns C<invalid>, C<not_found>, C<conflict>, or C<failed> statuses instead of
throwing for expected write outcomes. Unexpected store or command-log
exceptions are logged and mapped to C<failed>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses deletion, export, hold, and review services supplied by the composition
root. C<erased_exports> defaults to one over the export store's schema, and
to none when the store has no schema.

=head1 DEPENDENCIES

Uses L<GPForum::Base> and L<GPForum::Service::Privacy::ErasedExports>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Command-id is required for export, deletion, approval, hold, and erasure
writes. Open deletion requests, pending exports, and active holds replay on
retry. The same export C<command_id> replays from C<command_log> after the
bundle is already completed. C<hold_request> stays four arguments besides
the invocant.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
