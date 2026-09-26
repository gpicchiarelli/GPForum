# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::CommandIdempotency;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Digest::SHA qw(sha256_hex);
use English     qw(-no_match_vars);
use JSON::MaybeXS;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Infrastructure::Id;

our $VERSION = '0.001';

const my $ID_CONSTRAINT  => 'command_log_pkey';
const my $KEY_CONSTRAINT => 'command_log_idempotency_key_key';
const my $FAILED_STATUS  => 'failed';
const my $ABANDONED      => __PACKAGE__ . '::Abandoned';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Infrastructure::Id->new; };
has schema     => undef;

# A workflow command run through run(), answered in the shape every workflow
# returns: the stored response on a replay, the new result, or a refusal --
# invalid without a command id, conflict when the id belongs to another
# request or is still running. $job holds actor_id, command_id,
# command_type, request and run. Seven workflows carried their own copy of
# this (ADR 0110).
sub result_of ( $self, $job ) {
    my $guarded = $self->run(
        {
            actor_id     => $job->{actor_id},
            command_id   => _trim( $job->{command_id} ),
            command_type => $job->{command_type},
            request      => $job->{request} || {},
        },
        $job->{run},
        sub ($result) { return $result; },
    );
    return $guarded->{response} if $guarded->{replayed};
    return $guarded->{result}   if $guarded->{recorded};

    return _refusal($guarded);
}

sub _refusal ($guarded) {
    my %refusal =
      $guarded->{invalid}
      ? (
        errors => { command_id => 'command_id is required' },
        status => 'invalid',
      )
      : ( error => $guarded->{error}, status => 'conflict' );

    return {
        error  => $refusal{error},
        errors => $refusal{errors},
        ok     => 0,
        status => $refusal{status},
        stored => undef,
    };
}

sub run ( $self, $input, $code, $response_builder ) {
    my $key = _command_key($input);
    if ( !length $key ) {
        return {
            error   => 'command_id is required',
            invalid => 1,
        };
    }

    my $request_hash = _canonical_hash( $input->{request} || {} );

    my $guarded = eval {
        return $self->schema->txn_do(
            sub {
                return $self->_run_inside_txn(
                    {
                        code             => $code,
                        input            => $input,
                        key              => $key,
                        request_hash     => $request_hash,
                        response_builder => $response_builder,
                    }
                );
            }
        );
    };
    return $guarded if $guarded;

    my $error = $EVAL_ERROR;
    if ( ref $error eq $ABANDONED ) {
        return {
            recorded    => 1,
            result      => $error->{result},
            rolled_back => 1,
        };
    }

    croak $error;
}

sub _run_inside_txn ( $self, $job ) {
    my $existing = $self->_find_existing( $job->{key} );
    if ($existing) {
        return $self->_existing_result( $existing, $job->{request_hash} );
    }

    return $self->_create_and_execute($job);
}

sub _create_and_execute ( $self, $job ) {
    my ( $row, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_command_row($job); },
      );
    if ($row) {
        return $self->_finish_new_command( $job, $row );
    }

    return $self->_replay_after_conflict( $job, $error );
}

sub _insert_command_row ( $self, $job ) {
    $job->{row} = $self->_command_row($job);
    return $self->_create_command( $job->{row} );
}

# A failed result is never the command's answer. Every workflow's guarded
# code catches its store's exception and returns 'failed' from inside this
# transaction. Committing then kept whatever the store wrote before it
# failed, whenever PostgreSQL survived the failure -- a savepoint rolled back,
# or not a database error at all -- and stored 'failed' as the command id's
# answer, so retrying the same command could never succeed. Abandoning the
# transaction leaves neither; run() hands the failure back uncommitted.
sub _finish_new_command ( $self, $job, $row ) {
    my $result = $job->{code}->();
    if ( _is_failed($result) ) {
        croak bless { result => $result }, $ABANDONED;
    }

    my $builder  = $job->{response_builder};
    my $response = $result;
    if ($builder) {
        $response = $builder->($result);
    }

    $self->_finish_command_row( $row, $result, $response );

    return {
        recorded => 1,
        result   => $result,
    };
}

sub _replay_after_conflict ( $self, $job, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_command_after_unique( $job, $error );
}

sub _command_after_unique ( $self, $job, $error ) {
    if ( _command_id_conflict($error) ) {
        return $self->_retry_or_reuse_command($job);
    }
    if ( _idempotency_key_conflict($error) ) {
        return $self->_replay_existing( $job, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _retry_or_reuse_command ( $self, $job ) {
    my $stored = $self->_command_by_id( $job->{row}{command_id} );
    if ( $self->_same_open_command( $stored, $job ) ) {
        return $self->_reuse_command( $job, $stored );
    }

    return $self->_retry_command_id($job);
}

sub _same_open_command ( $self, $stored, $job ) {
    if ( !$stored ) {
        return 0;
    }

    return _same_text( _column( $stored, 'idempotency_key' ), $job->{key} );
}

sub _reuse_command ( $self, $job, $stored ) {
    my $replayed = $self->_replay_if_complete( $job, $stored );
    if ($replayed) {
        return $replayed;
    }

    return $self->_finish_new_command( $job, $stored );
}

sub _replay_if_complete ( $self, $job, $stored ) {
    my $payload = _payload_hash( _column( $stored, 'payload' ) );
    if ( !_has_response($payload) ) {
        my $undefined;
        return $undefined;
    }

    return $self->_existing_result( $stored, $job->{request_hash} );
}

sub _command_by_id ( $self, $command_id ) {
    return $self->schema->resultset('CommandLog')
      ->find( { command_id => $command_id } );
}

sub _same_text ( $stored, $candidate ) {
    if ( !defined $stored || !defined $candidate ) {
        return 0;
    }

    return $stored eq $candidate ? 1 : 0;
}

sub _retry_command_id ( $self, $job ) {
    $job->{row} = { %{ $job->{row} }, command_id => $self->id_service->uuid, };
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_command( $job->{row} ); },
      );
    if ($created) {
        return $self->_finish_new_command( $job, $created );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _command_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _idempotency_key_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $KEY_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _replay_existing ( $self, $job, $error ) {
    my $existing = $self->_find_existing( $job->{key} );
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_existing_result( $existing, $job->{request_hash} );
}

sub _find_existing ( $self, $key ) {
    return $self->schema->resultset('CommandLog')
      ->search_rs( { idempotency_key => $key }, { rows => 1 } )
      ->single;
}

sub _existing_result ( $self, $row, $request_hash ) {
    my $payload = _payload_hash( _column( $row, 'payload' ) );
    if ( ( $payload->{request_hash} || q{} ) ne $request_hash ) {
        return {
            conflict => 1,
            error    => 'idempotency key was already used for another request',
        };
    }

    if ( !_has_response($payload) ) {
        return {
            in_progress => 1,
            error       => 'idempotency key is already in progress',
        };
    }

    return {
        replayed => 1,
        response => $payload->{response},
    };
}

sub _command_row ( $self, $job ) {
    return {
        actor_id        => _nullable_trim( $job->{input}{actor_id} ),
        command_id      => $self->id_service->uuid,
        command_type    => _trim( $job->{input}{command_type} ),
        correlation_id  => $self->id_service->uuid,
        created_at      => $self->clock->now_iso8601,
        handled_at      => undef,
        idempotency_key => $job->{key},
        payload         => { request_hash => $job->{request_hash} },
        response_hash   => undef,
        status          => 'accepted',
    };
}

sub _create_command ( $self, $row ) {
    return $self->schema->resultset('CommandLog')->create($row);
}

sub _finish_command_row ( $self, $row, $result, $response ) {
    my $payload = _payload_hash( _column( $row, 'payload' ) );
    $payload->{response} = $response || {};

    _update_row(
        $row,
        {
            handled_at    => $self->clock->now_iso8601,
            payload       => $payload,
            response_hash => _canonical_hash( $payload->{response} ),
            status        => _result_status($result),
        }
    );

    return;
}

sub _result_status ($result) {
    if ( ref $result ne 'HASH' ) {
        return 'rejected';
    }
    if ( $result->{ok} ) {
        return 'handled';
    }

    my $status = $result->{status} || q{};
    return $status eq 'failed' ? 'failed' : 'rejected';
}

sub _payload_hash ($payload) {
    if ( ref $payload ne 'HASH' ) {
        return {};
    }

    return { %{$payload} };
}

sub _has_response ($payload) {
    return ref $payload eq 'HASH' && exists $payload->{response} ? 1 : 0;
}

sub _canonical_hash ($value) {
    my $json = JSON::MaybeXS->new( canonical => 1, utf8 => 1 )
      ->encode( _defined_json_value($value) );

    return sha256_hex($json);
}

sub _is_failed ($result) {
    return 0 if ref $result ne 'HASH';

    return ( $result->{status} // q{} ) eq $FAILED_STATUS ? 1 : 0;
}

sub _command_key ($input) {
    my $source     = $input || {};
    my $command_id = _trim( $source->{command_id} );
    return $command_id if length $command_id;

    return _trim( $source->{idempotency_key} );
}

sub _defined_json_value ($value) {
    return defined $value ? $value : {};
}

sub _update_row ( $row, $values ) {
    return _update_object_row( $row, $values ) if _can_update_object($row);

    _update_hash_row( $row, $values );

    return $row;
}

sub _can_update_object ($row) {
    return $row && ref $row ne 'HASH' && $row->can('update') ? 1 : 0;
}

sub _update_object_row ( $row, $values ) {
    return $row->update($values);
}

sub _update_hash_row ( $row, $values ) {
    return if ref $row ne 'HASH';

    for my $key ( keys %{$values} ) {
        $row->{$key} = $values->{$key};
    }

    return;
}

sub _column ( $row, $name ) {
    my $undefined;
    return $undefined    if !$row;
    return $row->{$name} if ref $row eq 'HASH';
    if ( $row->can($name) ) {
        return $row->$name;
    }
    return $row->get_column($name) if $row->can('get_column');

    return $undefined;
}

sub _trim ($value) {
    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

sub _nullable_trim ($value) {
    my $trimmed = _trim($value);

    return length $trimmed ? $trimmed : undef;
}

1;
