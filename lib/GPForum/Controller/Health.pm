package GPForum::Controller::Health;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base 'Mojolicious::Controller';

our $VERSION = '0.001';

const my %STATUS_CODE_FOR => (
    ok       => 200,
    degraded => 200,
    fail     => 503,
);

sub live {
    my ($self) = @_;

    return $self->render(
        json => {
            status => 'ok',
            check  => 'live',
            time   => $self->gp_clock->now_iso8601,
        },
    );
}

sub ready {
    my ($self) = @_;

    my $readiness = $self->gp_readiness->check;

    return $self->render(
        json   => $readiness,
        status => $STATUS_CODE_FOR{ $readiness->{status} },
    );
}

sub summary {
    my ($self) = @_;

    return $self->render(
        json => {
            status      => 'ok',
            application => 'GPForum',
            environment => $self->gp_config->environment,
            runtime     => $self->gp_runtime->as_hash,
            os          => $self->gp_runtime->os_profile->snapshot,
            os_features => $self->gp_runtime->os_profile->feature_snapshot(
                $self->gp_runtime->os_feature_settings
            ),
            os_sockets => $self->gp_runtime->os_profile->socket_snapshot(
                $self->gp_runtime->os_feature_settings
            ),
            os_processes => $self->gp_runtime->os_profile->process_snapshot(
                $self->gp_runtime->os_feature_settings
            ),
            time => $self->gp_clock->now_iso8601,
        },
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
