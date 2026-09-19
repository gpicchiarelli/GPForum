package GPForum::Controller::Operations;

use strict;
use warnings;

use GPForum::Web::OperationsAccess;
use GPForum::Web::OperationsPayload;
use Mojo::Base 'Mojolicious::Controller';

our $VERSION = '0.001';

has operations_access => sub { return GPForum::Web::OperationsAccess->new; };

sub metrics {
    my ($self) = @_;

    if (
        !$self->operations_access->metrics_authorized( $self->_metrics_input ) )
    {
        return $self->_unauthorized_metrics;
    }

    return $self->render(
        json => GPForum::Web::OperationsPayload->metrics(
            snapshot => $self->gp_metrics_snapshot->collect,
        ),
    );
}

sub _metrics_input {
    my ($self) = @_;

    return {
        authorization    => $self->req->headers->header('Authorization') || q{},
        configured_token => $self->gp_config->metrics_token,
        metrics_header   => $self->req->headers->header(
            $self->operations_access->metrics_token_header
          )
          || q{},
    };
}

sub _unauthorized_metrics {
    my ($self) = @_;

    my $payload = $self->operations_access->unauthorized_payload;

    return $self->render(
        json   => $payload->{json},
        status => $payload->{status},
    );
}

1;

__END__

=head1 NAME

GPForum::Controller::Operations - Internal metrics endpoint.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->get('/metrics')->to('Operations#metrics');

=head1 DESCRIPTION

Renders the process-local metrics snapshot. Token matching and the
unauthorized JSON payload live on L<GPForum::Web::OperationsAccess>. Snapshot
shape lives on L<GPForum::Web::OperationsPayload>.

=head1 SUBROUTINES/METHODS

=head2 metrics

Returns the metrics snapshot, or HTTP 401 when a configured token is missing
from the request.

=head1 DIAGNOSTICS

Missing or invalid metrics tokens render C<401> JSON
C<metrics token required>.

=head1 CONFIGURATION AND ENVIRONMENT

Reads C<metrics_token> from application config.

=head1 DEPENDENCIES

Uses L<GPForum::Web::OperationsAccess> and L<GPForum::Web::OperationsPayload>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Network allowlists stay on the reverse proxy. Snapshot collection stays on
the metrics helper.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
