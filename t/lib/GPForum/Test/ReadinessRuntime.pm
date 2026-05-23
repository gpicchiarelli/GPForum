package GPForum::Test::ReadinessRuntime;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub as_hash {
    return {
        mode => 'test',
        os   => {
            name          => 'test',
            event_backend => 'test',
        },
    };
}

1;
