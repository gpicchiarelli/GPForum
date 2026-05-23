package GPForum::Test::ProjectionGenerationSchema;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

our $VERSION = '0.001';

has generation_resultset => undef;

sub resultset {
    my ( $self, $name ) = @_;

    return $self->generation_resultset if $name eq 'ProjectionGeneration';

    croak 'unexpected resultset';
}

1;
