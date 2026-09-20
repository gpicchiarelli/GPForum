package GPForum::Service::Operations::CommandIdempotency;

use strict;
use warnings;

use Const::Fast;
use Digest::SHA qw(sha256_hex);
use JSON::MaybeXS;
use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $ID_CONSTRAINT  => 'command_log_pkey';
const my $KEY_CONSTRAINT => 'command_log_idempotency_key_key';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub run {
    my ( $self, $input, $code, $response_builder ) = @_;

    my $key = _command_key($input);
    if ( !length $key ) {
        return {
            error   => 'command_id is required',
            invalid => 1,
        };
    }

    my $request_hash = _canonical_hash( $input->{request} || {} );

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
}

sub _run_inside_txn {
    my ( $self, $job ) = @_;

    my $existing = $self->_find_existing( $job->{key} );
    if ($existing) {
        return $self->_existing_result( $existing, $job->{request_hash} );
    }

    return $self->_create_and_execute($job);
}

sub _create_and_execute {
    my ( $self, $job ) = @_;

    my ( $row, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_command_row($job); },
      );
    if ($row) {
        return $self->_finish_new_command( $job, $row );
    }

    return $self->_replay_after_conflict( $job, $error );
}

sub _insert_command_row {
    my ( $self, $job ) = @_;

    $job->{row} = $self->_command_row($job);
    return $self->_create_command( $job->{row} );
}

sub _finish_new_command {
    my ( $self, $job, $row ) = @_;

    my $result   = $job->{code}->();
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

sub _replay_after_conflict {
    my ( $self, $job, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_command_after_unique( $job, $error );
}

sub _command_after_unique {
    my ( $self, $job, $error ) = @_;

    if ( _command_id_conflict($error) ) {
        return $self->_retry_or_reuse_command($job);
    }
    if ( _idempotency_key_conflict($error) ) {
        return $self->_replay_existing( $job, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _retry_or_reuse_command {
    my ( $self, $job ) = @_;

    my $stored = $self->_command_by_id( $job->{row}{command_id} );
    if ( $self->_same_open_command( $stored, $job ) ) {
        return $self->_reuse_command( $job, $stored );
    }

    return $self->_retry_command_id($job);
}

sub _same_open_command {
    my ( $self, $stored, $job ) = @_;

    if ( !$stored ) {
        return 0;
    }

    return _same_text( _column( $stored, 'idempotency_key' ), $job->{key} );
}

sub _reuse_command {
    my ( $self, $job, $stored ) = @_;

    my $replayed = $self->_replay_if_complete( $job, $stored );
    if ($replayed) {
        return $replayed;
    }

    return $self->_finish_new_command( $job, $stored );
}

sub _replay_if_complete {
    my ( $self, $job, $stored ) = @_;

    my $payload = _payload_hash( _column( $stored, 'payload' ) );
    if ( !_has_response($payload) ) {
        return;
    }

    return $self->_existing_result( $stored, $job->{request_hash} );
}

sub _command_by_id {
    my ( $self, $command_id ) = @_;

    return $self->schema->resultset('CommandLog')
      ->find( { command_id => $command_id } );
}

sub _same_text {
    my ( $stored, $candidate ) = @_;

    if ( !defined $stored || !defined $candidate ) {
        return 0;
    }

    return $stored eq $candidate ? 1 : 0;
}

sub _retry_command_id {
    my ( $self, $job ) = @_;

    $job->{row} = { %{ $job->{row} }, command_id => $self->id_service->uuid, };
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_command( $job->{row} ); },
      );
    if ($created) {
        return $self->_finish_new_command( $job, $created );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _command_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _idempotency_key_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $KEY_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _replay_existing {
    my ( $self, $job, $error ) = @_;

    my $existing = $self->_find_existing( $job->{key} );
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_existing_result( $existing, $job->{request_hash} );
}

sub _find_existing {
    my ( $self, $key ) = @_;

    return $self->schema->resultset('CommandLog')
      ->search( { idempotency_key => $key }, { rows => 1 } )
      ->single;
}

sub _existing_result {
    my ( $self, $row, $request_hash ) = @_;

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

sub _command_row {
    my ( $self, $job ) = @_;

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

sub _create_command {
    my ( $self, $row ) = @_;

    return $self->schema->resultset('CommandLog')->create($row);
}

sub _finish_command_row {
    my ( $self, $row, $result, $response ) = @_;

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

sub _result_status {
    my ($result) = @_;

    if ( ref $result ne 'HASH' ) {
        return 'rejected';
    }
    if ( $result->{ok} ) {
        return 'handled';
    }

    my $status = $result->{status} || q{};
    return $status eq 'failed' ? 'failed' : 'rejected';
}

sub _payload_hash {
    my ($payload) = @_;

    if ( ref $payload ne 'HASH' ) {
        return {};
    }

    return { %{$payload} };
}

sub _has_response {
    my ($payload) = @_;

    return ref $payload eq 'HASH' && exists $payload->{response} ? 1 : 0;
}

sub _canonical_hash {
    my ($value) = @_;

    my $json = JSON::MaybeXS->new( canonical => 1, utf8 => 1 )
      ->encode( _defined_json_value($value) );

    return sha256_hex($json);
}

sub _command_key {
    my ($input) = @_;

    my $source     = $input || {};
    my $command_id = _trim( $source->{command_id} );
    return $command_id if length $command_id;

    return _trim( $source->{idempotency_key} );
}

sub _defined_json_value {
    my ($value) = @_;

    return defined $value ? $value : {};
}

sub _update_row {
    my ( $row, $values ) = @_;

    return _update_object_row( $row, $values ) if _can_update_object($row);

    _update_hash_row( $row, $values );

    return $row;
}

sub _can_update_object {
    my ($row) = @_;

    return $row && ref $row ne 'HASH' && $row->can('update') ? 1 : 0;
}

sub _update_object_row {
    my ( $row, $values ) = @_;

    return $row->update($values);
}

sub _update_hash_row {
    my ( $row, $values ) = @_;

    return if ref $row ne 'HASH';

    for my $key ( keys %{$values} ) {
        $row->{$key} = $values->{$key};
    }

    return;
}

sub _column {
    my ( $row, $name ) = @_;

    return               if !$row;
    return $row->{$name} if ref $row eq 'HASH';
    if ( $row->can($name) ) {
        return $row->$name;
    }
    return $row->get_column($name) if $row->can('get_column');

    return;
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

sub _nullable_trim {
    my ($value) = @_;

    my $trimmed = _trim($value);

    return length $trimmed ? $trimmed : undef;
}

1;
