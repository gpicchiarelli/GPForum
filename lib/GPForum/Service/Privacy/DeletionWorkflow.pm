# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Privacy::DeletionWorkflow;

use Const::Fast;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::Storage;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Identity::Support;
use GPForum::Service::Privacy::Completion;
use GPForum::Service::Privacy::ErasedExports;
use GPForum::Service::Privacy::Erasure;
use GPForum::Service::Privacy::Event;
use GPForum::Service::Privacy::Record;
use GPForum::X::Conflict;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

our $VERSION = '0.001';

const my $STATUS_PENDING         => 'pending';
const my $STATUS_APPROVED        => 'approved';
const my $STATUS_COMPLETED       => 'completed';
const my $STATUS_HELD            => 'held';
const my $JOB_PENDING            => 'pending';
const my $JOB_DONE               => 'done';
const my $LEGAL_HOLD             => 'legal hold';
const my $DELETION_ID_CONSTRAINT => 'deletion_requests_pkey';
const my $OPEN_DELETION_CONSTRAINT =>
  'idx_deletion_requests_open_resource_unique';
const my $ERASURE_ID_CONSTRAINT      => 'erasure_jobs_pkey';
const my $ERASURE_REQUEST_CONSTRAINT => 'idx_erasure_jobs_request_unique';
const my $ACTION_ID_CONSTRAINT       => 'deletion_actions_pkey';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};
has recorder => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
__PACKAGE__->requires(qw(schema));
has record     => sub { return GPForum::Service::Privacy::Record->new; };
has completion => sub {
    my ($self) = @_;

    return GPForum::Service::Privacy::Completion->new( record => $self->record,
    );
};
has erasure => sub {
    my ($self) = @_;

    return GPForum::Service::Privacy::Erasure->new( record => $self->record );
};
has events => sub {
    my ($self) = @_;

    return GPForum::Service::Privacy::Event->new( record => $self->record );
};
has erased_exports => sub {
    my ($self) = @_;

    return GPForum::Service::Privacy::ErasedExports->new(
        record => $self->record,
        schema => $self->schema,
    );
};

# Under a lock on the resource's open requests, an open request is reused;
# otherwise a new one is inserted. A concurrent insert of the same open
# request, or a minted id already stored, is answered by the request then
# found; a minted id with no such request is minted once more.
sub request_deletion ( $self, $input ) {
    return $self->schema->txn_do(
        sub {
            my $dbh = GPForum::Infrastructure::Storage->dbh_of( $self->schema );
            if ($dbh) {
                $dbh->selectrow_array(
'SELECT deletion_request_id FROM deletion_requests WHERE resource_type = ? AND resource_id = ? AND request_type = ? AND status IN (?, ?, ?) FOR UPDATE',
                    undef,
                    $input->{resource_type},
                    $input->{resource_id},
                    $input->{request_type},
                    $STATUS_PENDING,
                    $STATUS_APPROVED,
                    $STATUS_HELD,
                );
            }
            my $existing = $self->_open_deletion_hash($input);
            if ($existing) {
                return $self->_finish_leftover_deletion($existing);
            }

            my $create = sub {
                my $request = {
                    completed_at        => undef,
                    created_at          => $self->clock->now_iso8601,
                    deletion_request_id => $self->id_service->uuid,
                    reason              => $input->{reason} || q{},
                    request_type        => $input->{request_type},
                    requester_user_id   => $input->{requester_user_id},
                    resource_id         => $input->{resource_id},
                    resource_type       => $input->{resource_type},
                    status              => $STATUS_PENDING,
                };
                $self->schema->resultset('DeletionRequest')->create($request);
                $self->_record_privacy_event_and_audit(
                    $self->events->requested(
                        {
                            actor_id => $input->{requester_user_id},
                            request  => $request,
                        }
                    )
                );

                return $request;
            };
            my ( $created, $error ) =
              GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
                $create );
            if ($created) {
                return $created;
            }

            my $conflict = GPForum::X::Conflict->caught($error);
            my $id_taken = $conflict && $conflict->on($DELETION_ID_CONSTRAINT);
            if ( $id_taken
                || ( $conflict && $conflict->on($OPEN_DELETION_CONSTRAINT) ) )
            {
                $existing = $self->_open_deletion_hash($input);
                if ($existing) {
                    return $self->_finish_leftover_deletion($existing);
                }
                if ($id_taken) {
                    return $self->_once_more($create);
                }
            }

            GPForum::Infrastructure::UniqueConflict->rethrow($error);
        }
    );
}

# Under a lock on the request, an approval whose job an earlier attempt
# already scheduled finishes that attempt; a request under an active hold is
# held instead; otherwise the request is approved and its erasure job
# scheduled.
sub approve_request ( $self, $request_id, $actor_id, $reason ) {
    return $self->schema->txn_do(
        sub {
            my $dbh = GPForum::Infrastructure::Storage->dbh_of( $self->schema );
            if ($dbh) {
                $dbh->selectrow_array(
'SELECT deletion_request_id FROM deletion_requests WHERE deletion_request_id = ? FOR UPDATE',
                    undef, $request_id
                );
            }
            my $request =
              $self->schema->resultset('DeletionRequest')->find($request_id);
            if ( !$request ) {
                return undef;
            }

            my $input = {
                actor_id   => $actor_id,
                reason     => $reason,
                request    => $request,
                request_id => $request_id,
                timestamp  => $self->clock->now_iso8601,
            };
            my $existing = $self->_existing_job_for($request_id);
            if ($existing) {
                return $self->_finish_leftover_approval( $input, $existing );
            }

            my $hold = $self->_active_hold_for_request($request);
            if ($hold) {
                return $self->_hold_request(
                    {
                        actor_id  => $actor_id,
                        hold      => $hold,
                        reason    => $self->completion->hold_reason($reason),
                        request   => $request,
                        timestamp => $input->{timestamp},
                    }
                );
            }

            $self->_set_request_status( $request, $STATUS_APPROVED );
            my $inserted = $self->_insert_or_reuse_job($input);
            if ( $inserted->{reused} ) {
                return $self->_finish_leftover_approval( $input,
                    $inserted->{job} );
            }

            return $self->_emit_approval( $input, $inserted->{job} );
        }
    );
}

# A job done by an earlier attempt is replayed, its request completed if
# that attempt left it open. Otherwise an active hold on the request blocks
# the erasure, and without one the subject is erased.
sub complete_job ( $self, $erasure_job_id, $actor_id ) {
    return $self->schema->txn_do(
        sub {
            my $job =
              $self->schema->resultset('ErasureJob')->find($erasure_job_id);
            if ( !$job ) {
                return undef;
            }
            if ( $self->completion->job_done($job) ) {
                my $left_open =
                  $self->schema->resultset('DeletionRequest')
                  ->find(
                    $self->record->column( $job, 'deletion_request_id' ) );
                if ($left_open) {
                    my $completed_at =
                      $self->record->column( $job, 'completed_at' );
                    if ( !defined $completed_at || !length $completed_at ) {
                        $completed_at = $self->clock->now_iso8601;
                    }
                    $self->_complete_request_row( $left_open, $completed_at );
                }
                return $self->completion->completion_replay($erasure_job_id);
            }

            my $request = $self->schema->resultset('DeletionRequest')
              ->find( $job->get_column('deletion_request_id') );
            if ( !$request ) {
                return undef;
            }

            my $input = {
                actor_id       => $actor_id,
                erasure_job_id => $erasure_job_id,
                job            => $job,
                request        => $request,
                timestamp      => $self->clock->now_iso8601,
            };
            my $hold = $self->_active_hold_for_request($request);
            if ($hold) {
                $input->{hold} = $hold;
                return $self->_block_erasure($input);
            }

            return $self->_finish_erasure($input);
        }
    );
}

sub hold_request ( $self, $request_id, $actor_id, $reason, $hold ) {
    return $self->schema->txn_do(
        sub {
            my $request =
              $self->schema->resultset('DeletionRequest')->find($request_id);
            if ( !$request ) {
                return undef;
            }

            my $held = $self->_hold_request(
                {
                    actor_id  => $actor_id,
                    hold      => $hold,
                    reason    => $reason || $LEGAL_HOLD,
                    request   => $request,
                    timestamp => $self->clock->now_iso8601,
                }
            );

            return { %{$held}, error => undef, ok => 1 };
        }
    );
}

# An earlier attempt may have committed the request without its event.
sub _finish_leftover_deletion ( $self, $existing ) {
    my $event_key = join q{:}, 'privacy.deletion_requested',
      $existing->{deletion_request_id};
    if ( !$self->recorder->event_recorded($event_key) ) {
        $self->_record_privacy_event_and_audit(
            $self->events->requested(
                {
                    actor_id => $existing->{requester_user_id},
                    request  => $existing,
                }
            )
        );
    }

    return $existing;
}

sub _finish_leftover_approval ( $self, $input, $job ) {
    my $released = $self->_latest_row(
        'DeletionAction',
        {
            action_type         => 'released',
            deletion_request_id => $input->{request_id},
        },
        'created_at',
    );
    if ($released) {
        return $self->completion->approval_replay( $input->{request_id}, $job );
    }

    $self->_set_request_status( $input->{request}, $STATUS_APPROVED );
    return $self->_emit_approval( $input, $job );
}

sub _emit_approval ( $self, $input, $job ) {
    my $action = $self->_record_action(
        $input->{request_id},
        {
            action_type => 'released',
            actor_id    => $input->{actor_id},
            created_at  => $input->{timestamp},
            metadata    => {
                reason => $input->{reason} || q{},
                status => $STATUS_APPROVED,
            },
        }
    );
    $self->_record_privacy_event_and_audit(
        $self->events->approved(
            {
                %{$input},
                action => $action,
                job    => $job,
            }
        )
    );

    return {
        action     => $action,
        job        => $self->record->job_hash($job),
        ok         => 1,
        request_id => $input->{request_id},
    };
}

# A concurrent approval's job, or a minted id already stored, is answered by
# the request's job then found; a minted id with no such job is minted once
# more.
sub _insert_or_reuse_job ( $self, $input ) {
    my $create = sub {
        my $job = {
            completed_at        => undef,
            deletion_request_id => $input->{request_id},
            erasure_job_id      => $self->id_service->uuid,
            last_error          => undef,
            scheduled_at        => $input->{timestamp},
            status              => $JOB_PENDING,
        };
        $self->schema->resultset('ErasureJob')->create($job);

        return $job;
    };
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $create );
    if ($created) {
        return { job => $created, reused => 0 };
    }

    my $conflict = GPForum::X::Conflict->caught($error);
    my $id_taken = $conflict && $conflict->on($ERASURE_ID_CONSTRAINT);
    if ( $id_taken
        || ( $conflict && $conflict->on($ERASURE_REQUEST_CONSTRAINT) ) )
    {
        my $existing = $self->_existing_job_for( $input->{request_id} );
        if ($existing) {
            return { job => $existing, reused => 1 };
        }
        if ($id_taken) {
            return { job => $self->_once_more($create), reused => 0 };
        }
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

# A request already held whose job already carries the hold's error is a
# replay. Otherwise both are marked; the action and the event are recorded
# only by the attempt that found neither marked.
sub _block_erasure ( $self, $input ) {
    my $held = $self->_already_held( $input->{request} );
    my $blocked =
      ( $self->record->column( $input->{job}, 'last_error' ) || q{} ) eq
      $self->events->block_error;
    if ( $held && $blocked ) {
        return $self->completion->hold_block_replay( $input->{erasure_job_id} );
    }

    $self->_set_request_status( $input->{request}, $STATUS_HELD );
    if ( !$blocked ) {
        $input->{job}->update( { last_error => $self->events->block_error } );
    }
    if ( $held || $blocked ) {
        return $self->_blocked_result($input);
    }

    my $action = $self->_record_action(
        $self->record->column( $input->{request}, 'deletion_request_id' ),
        {
            action_type => 'held',
            actor_id    => $input->{actor_id},
            created_at  => $input->{timestamp},
            metadata    => {
                erasure_job_id    => $input->{erasure_job_id},
                retention_hold_id =>
                  $self->record->column( $input->{hold}, 'retention_hold_id' ),
            },
        }
    );
    $self->_record_privacy_event_and_audit(
        $self->events->blocked( { %{$input}, action => $action } ) );

    return $self->_blocked_result( $input, $action );
}

sub _blocked_result ( $self, $input, $action = undef ) {
    return {
        action         => $action,
        erasure_job_id => $input->{erasure_job_id},
        error          => 'retention_hold_active',
        ok             => 0,
    };
}

# A job a hold stopped keeps the hold's last_error until it runs: done, it
# is no longer blocked, and the review read it as still held. The member's
# export bundles are copies of what the erasure removes, so they go too.
sub _finish_erasure ( $self, $input ) {
    my $anonymized =
      $self->_anonymize_request_subject( $input->{request},
        $input->{timestamp} );
    $input->{discarded_exports} =
      defined $anonymized->{user_id}
      ? $self->erased_exports->discard( $anonymized->{user_id} )
      : [];
    $input->{job}->update(
        {
            completed_at => $input->{timestamp},
            last_error   => undef,
            status       => $JOB_DONE,
        }
    );
    $self->_complete_request_row( $input->{request}, $input->{timestamp} );

    my $action = $self->_record_action(
        $self->record->column( $input->{request}, 'deletion_request_id' ),
        {
            action_type => 'anonymized',
            actor_id    => $input->{actor_id},
            created_at  => $input->{timestamp},
            metadata    => {
                anonymized     => $anonymized,
                erasure_job_id => $input->{erasure_job_id},
            },
        }
    );
    $self->_record_privacy_event_and_audit(
        $self->events->completed(
            {
                %{$input},
                action     => $action,
                anonymized => $anonymized,
            }
        )
    );

    return {
        action         => $action,
        anonymized     => $anonymized,
        erasure_job_id => $input->{erasure_job_id},
        ok             => 1,
    };
}

sub _open_deletion_hash ( $self, $input ) {
    my $row = $self->_latest_row(
        'DeletionRequest',
        {
            request_type  => $input->{request_type},
            resource_id   => $input->{resource_id},
            resource_type => $input->{resource_type},
            status        => {
                -in => [ $STATUS_PENDING, $STATUS_APPROVED, $STATUS_HELD ],
            },
        },
        'created_at',
    );
    if ( !$row ) {
        return undef;
    }

    return $self->record->request_hash($row);
}

# A minted action id already stored is minted once more.
sub _record_action ( $self, $request_id, $input ) {
    my $create = sub {
        my $action = {
            action_type         => $input->{action_type},
            actor_id            => $input->{actor_id},
            created_at          => $input->{created_at},
            deletion_action_id  => $self->id_service->uuid,
            deletion_request_id => $request_id,
            metadata            => $input->{metadata} || {},
        };
        $self->schema->resultset('DeletionAction')->create($action);

        return $action;
    };
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $create );
    if ($created) {
        return $created;
    }

    my $conflict = GPForum::X::Conflict->caught($error);
    if ( $conflict && $conflict->on($ACTION_ID_CONSTRAINT) ) {
        return $self->_once_more($create);
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

# The second attempt after a minted id collided: any failure is final.
sub _once_more ( $self, $create ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $create );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

# A request already held only reports the hold; otherwise it is held, and
# the action and the event are recorded.
sub _hold_request ( $self, $input ) {
    my $request    = $input->{request};
    my $request_id = $self->record->column( $request, 'deletion_request_id' );
    my $action;
    if ( !$self->_already_held($request) ) {
        $self->_set_request_status( $request, $STATUS_HELD );
        $action = $self->_record_action(
            $request_id,
            {
                action_type => 'held',
                actor_id    => $input->{actor_id},
                created_at  => $input->{timestamp},
                metadata    => {
                    reason            => $input->{reason},
                    retention_hold_id => $self->record->column(
                        $input->{hold}, 'retention_hold_id'
                    ),
                },
            }
        );
        $self->_record_privacy_event_and_audit( $self->events->held($input) );
    }

    return {
        action     => $action,
        error      => 'retention_hold_active',
        ok         => 0,
        request_id => $request_id,
    };
}

sub _already_held ( $self, $request ) {
    return $self->_same_request_status( $request, $STATUS_HELD );
}

sub _same_request_status ( $self, $request, $status ) {
    my $held = $self->record->column( $request, 'status' ) || q{};
    if ( $held eq $status ) {
        return 1;
    }

    return 0;
}

sub _set_request_status ( $self, $request, $status ) {
    if ( $self->_same_request_status( $request, $status ) ) {
        return;
    }

    $request->update( { status => $status } );

    return;
}

sub _complete_request_row ( $self, $request, $timestamp ) {
    if ( $self->_same_request_status( $request, $STATUS_COMPLETED ) ) {
        return;
    }

    $request->update(
        {
            completed_at => $timestamp,
            status       => $STATUS_COMPLETED,
        }
    );

    return;
}

sub _existing_job_for ( $self, $request_id ) {
    return $self->_latest_row( 'ErasureJob',
        { deletion_request_id => $request_id },
        'scheduled_at', );
}

sub _active_hold_for_request ( $self, $request ) {
    return $self->_latest_row(
        'RetentionHold',
        {
            ends_at       => undef,
            resource_id   => $self->record->column( $request, 'resource_id' ),
            resource_type => $self->record->column( $request, 'resource_type' ),
        },
        'created_at',
    );
}

sub _latest_row ( $self, $resultset_name, $query, $order_field ) {
    my $search = $self->schema->resultset($resultset_name)->search_rs(
        $query,
        {
            order_by => [ { -desc => $order_field } ],
            rows     => 1,
        }
    );
    if ( $search->can('single') ) {
        return $search->single;
    }

    my @rows = $self->record->rows($search);
    return $rows[0];
}

# A user resource is erased, its credentials and sessions revoked, unless
# the erasure policy names a reason to skip it.
#
# The credentials go first, in the order a login takes its locks: it holds
# the credential it verified FOR SHARE while it inserts its session, whose
# foreign key then share-locks the account row. The erasure anonymized the
# account first -- a new username, so a FOR UPDATE lock on the row -- and
# then waited for the credential, the login waited for the account row, and
# PostgreSQL broke the deadlock by aborting one of them, mostly the erasure,
# while the login kept its session. Revoking the credentials first waits for
# that login to commit, and its session is revoked with the others.
sub _anonymize_request_subject ( $self, $request, $timestamp ) {
    my $user_id = $self->record->column( $request, 'resource_id' );
    my $user =
        $self->erasure->is_user_resource($request)
      ? $self->schema->resultset('User')->find($user_id)
      : undef;
    my $skip = $self->erasure->skip_reason( $request, $user );
    if ($skip) {
        return $self->completion->skipped($skip);
    }

    $self->_revoke_user_rows( 'Credential', $user_id, $timestamp );
    my $already = $self->erasure->already_deleted($user);
    if ( !$already ) {
        $user->update( $self->erasure->user_values( $user_id, $timestamp ) );
    }
    $self->_revoke_user_rows( 'Session', $user_id, $timestamp );

    return $self->erasure->result( $user_id, $already );
}

# A source that cannot be read fails the erasure, which rolls back and runs
# again. It was skipped: the account was anonymized and its credentials
# revoked while its sessions stayed signed in (t/339).
sub _revoke_user_rows ( $self, $resultset_name, $user_id, $timestamp ) {
    my $search = $self->schema->resultset($resultset_name)->search_rs(
        {
            revoked_at => undef,
            user_id    => $user_id,
        }
    );
    for my $row ( $self->record->rows($search) ) {
        if ( $row && $row->can('update') ) {
            $row->update(
                {
                    revoked_at => _not_before_creation(
                        $timestamp, $self->record->column( $row, 'created_at' )
                    )
                }
            );
        }
    }

    return undef;
}

# The erasure's time, or the row's creation when that is later: the session
# of a login the erasure waited for was stamped after the erasure read its
# clock, or by a host whose clock is ahead, and a revocation before the
# creation is refused by the revoked_after_created checks, failing the
# erasure. Compared to the second, the creation wins a tie, since it may
# carry a fraction the erasure's time does not.
sub _not_before_creation ( $timestamp, $created_at ) {
    my $support = 'GPForum::Service::Identity::Support';
    my $created = $support->epoch_from_timestamp($created_at);
    my $revoked = $support->epoch_from_timestamp($timestamp);
    if ( defined $created && defined $revoked && $created >= $revoked ) {
        return $created_at;
    }

    return $timestamp;
}

sub _record_privacy_event_and_audit ( $self, $input ) {
    my $correlation_id = $self->id_service->uuid;
    $self->recorder->record_event(
        %{ $self->events->envelope( $input, $correlation_id ) } );
    $self->recorder->record_audit(
        %{ $self->events->audit( $input, $correlation_id ) } );

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Privacy::DeletionWorkflow - Deletion requests, their approval, legal holds and the erasure job that anonymizes a member.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $deletion = GPForum::Service::Privacy::DeletionWorkflow->new(
        clock      => $clock,
        id_service => $id_service,
        schema     => $schema,
    );
    my $request = $deletion->request_deletion(
        {
            reason            => 'leaving the forum',
            request_type      => 'anonymize',
            requester_user_id => $user_id,
            resource_id       => $user_id,
            resource_type     => 'user',
        }
    );
    my $approved = $deletion->approve_request(
        $request->{deletion_request_id}, $admin_id, 'verified' );
    if ( $approved && $approved->{ok} ) {
        $deletion->complete_job( $approved->{job}{erasure_job_id}, $admin_id );
    }

=head1 DESCRIPTION

Owns the writes behind a member's deletion: it writes C<deletion_requests>,
C<erasure_jobs> and C<deletion_actions>, anonymizes the member when the job
runs, and records a privacy event and audit entry for each step, built by
L<GPForum::Service::Privacy::Event> and written by
L<GPForum::Infrastructure::EventRecorder>. L<GPForum::Service::Privacy::Workflow>
validates the commands and calls it. Each public method runs in one
transaction, and every step can be repeated: a step already taken is
answered from what is stored rather than done twice, and one found
half-recorded -- a request without its event, a job without its approval
action -- is finished.

A request is C<pending> until approved. A resource has at most one open
(C<pending>, C<approved> or C<held>) request of a type: asking again returns
that request, and concurrent requests are serialized by locking the open
rows and by the unique index C<idx_deletion_requests_open_resource_unique>.
Approving locks the request, then schedules one C<pending> erasure job for
it -- unless the resource is under an active retention hold (one with no
C<ends_at>), in which case the request is put on hold instead. Running the
job checks the hold again: under a hold it marks the request C<held> and the
job's C<last_error>, and erases nothing; otherwise it anonymizes the member
(when the resource is a C<user> that exists), revokes their credentials and
sessions, discards the export bundles that copy their data, and marks the
job C<done> and the request C<completed>. The credentials are revoked before
the account is anonymized, the order a login takes its locks in, so an
erasure waits for a login opening a session instead of deadlocking with it;
each credential and session is revoked at the erasure's time, or at its own
C<created_at> when that is later.

Inserts run inside savepoints. A lost race on a unique index reuses the row
the other writer inserted; a collision on a generated id is retried once
with a fresh id.

=head1 SUBROUTINES/METHODS

=head2 request_deletion

Takes a hash reference with C<requester_user_id>, C<request_type>,
C<resource_type>, C<resource_id> and an optional C<reason> (empty when
omitted). Creates a C<pending> request and records
C<privacy.deletion_requested>, or returns the open request already there.
Returns the request as a hash reference: C<deletion_request_id>,
C<request_type>, C<requester_user_id>, C<resource_type>, C<resource_id>,
C<reason>, C<status>, C<created_at> and C<completed_at>.

=head2 approve_request

Takes a request id, the approving actor's id and a reason. Returns undef
when there is no such request. Otherwise:

=over 4

=item *

with no erasure job yet and no active hold, sets the request C<approved>,
schedules the job, records a C<released> deletion action and
C<privacy.deletion_approved>, and returns
C<< { ok => 1, request_id, action, job } >>, C<job> being the job as a hash
reference;

=item *

with an active hold, holds the request as C<hold_request> does (the reason
defaulting to C<active legal hold>) and returns
C<< { ok => 0, error => 'retention_hold_active', request_id, action } >>,
C<action> being undef when the request was already held;

=item *

when the request already has a job and a C<released> action, returns
C<< { ok => 1, idempotent => 1, request_id, job } >>; with a job but no
action yet, it finishes the approval as in the first case.

=back

=head2 complete_job

Takes an erasure job id and the acting user's id. Returns undef when there
is no such job, or when a job not yet done has no request. Otherwise:

=over 4

=item *

when the job is already C<done>, marks its request C<completed> if it is
not yet and returns C<< { ok => 1, idempotent => 1, erasure_job_id } >>;

=item *

under an active retention hold, sets the request C<held> and the job's
C<last_error> to C<retention hold active>, and returns
C<< { ok => 0, error => 'retention_hold_active', erasure_job_id, action } >>.
The C<held> deletion action and C<privacy.erasure_blocked> are recorded only
when the request was not yet held and the job not yet blocked; otherwise
C<action> is undef. When both were already so, it writes nothing and
returns
C<< { ok => 0, error => 'retention_hold_active', idempotent => 1, erasure_job_id } >>;

=item *

otherwise, when the resource is a C<user> that exists, anonymizes the member,
revokes their credentials and sessions, and discards their export bundles
through L<GPForum::Service::Privacy::ErasedExports> (the audit entry's
C<discarded_exports> names the requests deleted); in every case it marks the
job C<done>, clears its C<last_error> and marks the request C<completed>,
records an C<anonymized> deletion action and C<privacy.erasure_completed>,
and returns
C<< { ok => 1, erasure_job_id, action, anonymized } >>. C<anonymized> is
C<< { user_id, idempotent } >> (C<idempotent> 1 when the member was already
anonymized), or C<< { skipped => 'resource_not_user' } >> or
C<< { skipped => 'user_not_found' } >>.

=back

=head2 hold_request

Takes a request id, the acting user's id, a reason (default C<legal hold>)
and the retention hold row it is held under. Returns undef when there is no
such request. Otherwise sets the request C<held>, records a C<held>
deletion action naming the hold and C<privacy.deletion_held>, and returns
C<< { ok => 1, error => undef, request_id, action } >>; C<action> is undef
when the request was already held and nothing was written.

=head1 DIAGNOSTICS

Croaks with the database error when an insert fails for any reason other
than a unique conflict it knows, when a conflict leaves no row to reuse,
and when the retry after an id collision fails too. Every public method
runs in C<txn_do>, so any failure, including one recording the event or
the audit entry, rolls the whole step back and propagates. A retention hold
is not a failure: it is reported as C<< ok => 0 >> with
C<< error => 'retention_hold_active' >>.

=head1 CONFIGURATION AND ENVIRONMENT

None. C<clock>, C<id_service>, C<recorder>, C<record>, C<completion>,
C<erasure>, C<erased_exports> and C<events> have defaults; the application
passes its clock and id service.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::EventRecorder>, L<GPForum::Infrastructure::Id>,
L<GPForum::Infrastructure::Storage>,
L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::X::Conflict>,
L<GPForum::Service::Clock>, L<GPForum::Service::Identity::Support> (to
compare timestamps), L<GPForum::Service::Privacy::Completion>,
L<GPForum::Service::Privacy::ErasedExports>,
L<GPForum::Service::Privacy::Erasure>, L<GPForum::Service::Privacy::Event>,
L<GPForum::Service::Privacy::Record>.

Extends L<GPForum::Base>: built without C<schema> it throws
L<GPForum::X::Argument>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
