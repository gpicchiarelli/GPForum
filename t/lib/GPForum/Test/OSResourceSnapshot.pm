package GPForum::Test::OSResourceSnapshot;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has snapshot_data => sub {
    return {
        open_file_descriptors => 4,
        file_descriptor_limit => 4096,
        swap_pressure         => {
            status => 'ok',
        },
    };
};

sub snapshot {
    my ($self) = @_;

    return $self->snapshot_data;
}

1;
