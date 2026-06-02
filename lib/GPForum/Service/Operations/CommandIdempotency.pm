package GPForum::Service::Operations::CommandIdempotency;

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use JSON::MaybeXS;
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub run {
    my ( $self, $input, $code, $response_builder ) = @_;

    my $key = _trim( $input->{idempotency_key} );
    if ( !length $key ) {
        return { recorded => 0, result => $code->() };
    }

    my $request_hash = _canonical_hash( $input->{request} || {} );
    my $existing     = $self->_find_existing($key);
    if ($existing) {
        return $self->_existing_result( $existing, $request_hash );
    }

    return $self->schema->txn_do(
        sub {
            my $row = $self->_create_command_row( $input, $key, $request_hash );
            my $result = $code->();
            my $response =
              $response_builder ? $response_builder->($result) : $result;

            $self->_finish_command_row( $row, $result, $response );

            return {
                recorded => 1,
                result   => $result,
            };
        }
    );
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

sub _create_command_row {
    my ( $self, $input, $key, $request_hash ) = @_;

    return $self->schema->resultset('CommandLog')->create(
        {
            command_id      => $self->id_service->uuid,
            command_type    => _trim( $input->{command_type} ),
            actor_id        => _nullable_trim( $input->{actor_id} ),
            correlation_id  => $self->id_service->uuid,
            idempotency_key => $key,
            payload         => { request_hash => $request_hash },
            response_hash   => undef,
            status          => 'accepted',
            created_at      => $self->clock->now_iso8601,
            handled_at      => undef,
        }
    );
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

    return                         if !$row;
    return $row->{$name}           if ref $row eq 'HASH';
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
