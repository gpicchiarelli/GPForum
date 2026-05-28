package GPForum::Controller::Operations;

use strict;
use warnings;

use GPForum::Web::OperationsPayload;
use Mojo::Base 'Mojolicious::Controller';

our $VERSION = '0.001';

sub metrics {
    my ($self) = @_;

    return $self->render(
        json => GPForum::Web::OperationsPayload->metrics(
            snapshot => $self->gp_metrics_snapshot->collect,
        ),
    );
}

1;
