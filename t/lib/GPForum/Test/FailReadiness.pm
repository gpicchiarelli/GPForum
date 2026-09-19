package GPForum::Test::FailReadiness;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub check {
    return {
        status      => 'fail',
        checks      => [ { name => 'database', status => 'fail' } ],
        environment => 'test',
        runtime     => {},
        timestamp   => '2026-05-23T12:00:00Z',
    };
}

1;
