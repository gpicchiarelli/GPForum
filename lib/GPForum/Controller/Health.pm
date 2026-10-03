# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Health;

use strict;
use warnings;

use GPForum::Web::HealthPayload;
use GPForum::Web::OperationsAccess;
use Mojo::Base 'Mojolicious::Controller', -signatures;

our $VERSION = '0.001';

has operations_access => sub { return GPForum::Web::OperationsAccess->new; };

sub live ($self) {
    return $self->render(
        json => GPForum::Web::HealthPayload->live( clock => $self->gp_clock ),
    );
}

sub ready ($self) {
    my $readiness = $self->gp_readiness->check;
    my $body =
        $self->_full_report_allowed
      ? $readiness
      : GPForum::Web::HealthPayload->ready_anonymous($readiness);

    $self->_no_store;
    return $self->render(
        json   => $body,
        status => GPForum::Web::HealthPayload->ready_status_code(
            $readiness->{status}
        ),
    );
}

sub summary ($self) {
    $self->_no_store;
    if ( !$self->_full_report_allowed ) {
        return $self->render(
            json => GPForum::Web::HealthPayload->summary_anonymous );
    }

    return $self->render(
        json => GPForum::Web::HealthPayload->summary(
            config  => $self->gp_config,
            runtime => $self->gp_runtime,
            clock   => $self->gp_clock,
        ),
    );
}

# The body depends on the token headers; a shared cache must never replay a
# full report to an anonymous client.
sub _no_store ($self) {
    $self->res->headers->cache_control('no-store');
    return;
}

sub _full_report_allowed ($self) {
    return $self->operations_access->request_authorized( $self->req->headers,
        $self->gp_config );
}

1;

__END__

=head1 NAME

GPForum::Controller::Health - Health endpoints.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->get('/health')->to('Health#summary');

=head1 DESCRIPTION

Provides live, ready, and summary health endpoints.

C</health/live> answers C<status>, C<check> and C<time> to anyone: it names
nothing about the deployment. C</health/ready> and C</health> render their
full report only to a request carrying a valid metrics token, checked by
L<GPForum::Web::OperationsAccess> with the same C<Authorization: Bearer> and
C<X-GPForum-Metrics-Token> headers and the same rotation list as
C</metrics>. Without one -- no token, or a wrong one -- they answer the
status alone. A wrong token is not a 401 there, unlike C</metrics>: the
readiness code is what a load balancer acts on, so it stays 200 or 503 as
the readiness status decides, token or not. When no metrics token is
configured (development and test only; L<GPForum::Config> requires one in
staging and production) the full reports are open, as C</metrics> is.

Because their body depends on the token headers, C</health/ready> and
C</health> answer C<Cache-Control: no-store>, so no shared cache can replay a
full report to an anonymous client.

=head1 SUBROUTINES/METHODS

=head2 live

Renders a liveness response.

=head2 ready

Renders the readiness report with a valid metrics token, or only its
C<status> and C<check> without one. The HTTP code is 200 for C<ok> and
C<degraded>, 503 otherwise, either way.

=head2 summary

Renders the config, runtime and OS summary with a valid metrics token, or
C<< { status => 'ok' } >> without one.

=head1 DIAGNOSTICS

Rendering errors are reported by Mojolicious.

=head1 CONFIGURATION AND ENVIRONMENT

Reads C<metrics_token> and C<accepted_metrics_tokens> from the
application config to decide which body to render.

=head1 DEPENDENCIES

Uses L<Mojolicious::Controller>, L<GPForum::Web::HealthPayload> and
L<GPForum::Web::OperationsAccess>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Readiness performs lightweight local database checks only; external worker and
edge checks remain deployment responsibilities.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
