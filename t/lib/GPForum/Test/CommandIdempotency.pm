# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::CommandIdempotency;

use strict;
use warnings;

use parent 'GPForum::Service::Operations::CommandIdempotency';

our $VERSION = '0.001';

# Overrides run() only: result_of() is the real class's, so workflows are
# tested through the code that shapes their answers.

sub new {
    my ( $class, %arguments ) = @_;

    return bless {
        conflict        => $arguments{conflict},
        last_input      => undef,
        replay_response => $arguments{replay_response},
        response        => undef,
    }, $class;
}

sub last_input {
    my ( $self, $value ) = @_;

    if ( @_ > 1 ) {
        $self->{last_input} = $value;
    }

    return $self->{last_input};
}

sub response {
    my ( $self, $value ) = @_;

    if ( @_ > 1 ) {
        $self->{response} = $value;
    }

    return $self->{response};
}

sub run {
    my ( $self, $input, $code, $response_builder ) = @_;

    $self->last_input($input);

    if ( $self->{conflict} ) {
        return _conflict_result();
    }
    if ( $self->{replay_response} ) {
        return _replay_result( $self->{replay_response} );
    }

    my $result   = $code->();
    my $response = $response_builder->($result);
    $self->response($response);

    return {
        recorded => 1,
        response => $response,
        result   => $result,
    };
}

sub _conflict_result {
    return {
        conflict => 1,
        error    => 'idempotency key was already used for another request',
    };
}

sub _replay_result {
    my ($response) = @_;

    return {
        replayed => 1,
        response => $response,
    };
}

1;
