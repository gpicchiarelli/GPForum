package GPForum::Controller::Operations;

use strict;
use warnings;

use Const::Fast;
use GPForum::Web::OperationsPayload;
use Mojo::Base 'Mojolicious::Controller';

our $VERSION = '0.001';

const my $HTTP_UNAUTHORIZED => 401;

sub metrics {
    my ($self) = @_;

    return _unauthorized_metrics($self) if !_metrics_authorized($self);

    return $self->render(
        json => GPForum::Web::OperationsPayload->metrics(
            snapshot => $self->gp_metrics_snapshot->collect,
        ),
    );
}

sub _metrics_authorized {
    my ($controller) = @_;

    my $token = $controller->gp_config->metrics_token;
    return 1 if !defined $token || !length $token;

    return _metrics_bearer_authorized( $controller, $token )
      || _metrics_header_authorized( $controller, $token );
}

sub _metrics_bearer_authorized {
    my ( $controller, $token ) = @_;

    my $header = $controller->req->headers->header('Authorization') || q{};
    return _constant_time_equal( $header, "Bearer $token" );
}

sub _metrics_header_authorized {
    my ( $controller, $token ) = @_;

    my $header =
      $controller->req->headers->header('X-GPForum-Metrics-Token') || q{};
    return _constant_time_equal( $header, $token );
}

sub _unauthorized_metrics {
    my ($controller) = @_;

    return $controller->render(
        json => { status => 'unauthorized', error => 'metrics token required' },
        status => $HTTP_UNAUTHORIZED,
    );
}

sub _constant_time_equal {
    my ( $candidate, $expected ) = @_;

    return 0 if !_same_length_defined( $candidate, $expected );

    return _constant_time_diff( $candidate, $expected ) == 0 ? 1 : 0;
}

sub _same_length_defined {
    my ( $candidate, $expected ) = @_;

    return 0 if !defined $candidate || !defined $expected;
    return length $candidate == length $expected ? 1 : 0;
}

sub _constant_time_diff {
    my ( $candidate, $expected ) = @_;

    my $expected_length = length $expected;
    my $diff            = 0;
    for my $index ( 0 .. $expected_length - 1 ) {
        my $candidate_byte = ord substr $candidate, $index, 1;
        my $expected_byte  = ord substr $expected,  $index, 1;

        $diff |= $candidate_byte ^ $expected_byte;
    }

    return $diff;
}

1;
