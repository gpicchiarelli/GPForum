package GPForum::Controller::Health;

use strict;
use warnings;

use GPForum::Web::HealthPayload;
use Mojo::Base 'Mojolicious::Controller';

our $VERSION = '0.001';

sub live {
    my ($self) = @_;

    return $self->render(
        json => GPForum::Web::HealthPayload->live( clock => $self->gp_clock ),
    );
}

sub ready {
    my ($self) = @_;

    my $readiness = $self->gp_readiness->check;

    return $self->render(
        json   => $readiness,
        status => GPForum::Web::HealthPayload->ready_status_code(
            $readiness->{status}
        ),
    );
}

sub summary {
    my ($self) = @_;

    return $self->render(
        json => GPForum::Web::HealthPayload->summary(
            config  => $self->gp_config,
            runtime => $self->gp_runtime,
            clock   => $self->gp_clock,
        ),
    );
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

Provides live, ready, and summary health endpoints for milestone zero.

=head1 SUBROUTINES/METHODS

=head2 live

Renders a liveness response.

=head2 ready

Renders a readiness response.

=head2 summary

Renders a combined health response.

=head1 DIAGNOSTICS

Rendering errors are reported by Mojolicious.

=head1 CONFIGURATION AND ENVIRONMENT

Returns the active GPForum runtime and environment helpers.

=head1 DEPENDENCIES

Uses L<Mojolicious::Controller>.

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
