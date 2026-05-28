package GPForum::Web::OperationsPayload;

use strict;
use warnings;

our $VERSION = '0.001';

sub metrics {
    my ( undef, %input ) = @_;

    return $input{snapshot} || {};
}

1;
