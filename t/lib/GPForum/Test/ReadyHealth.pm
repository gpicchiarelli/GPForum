package GPForum::Test::ReadyHealth;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub check {
    return {
        status  => 'ok',
        check   => 'ready',
        runtime => {
            worker_processes   => 2,
            realtime_processes => 1,
        },
        checks      => [ { name => 'database', status => 'ok' } ],
        environment => 'test',
        timestamp   => '2026-05-23T12:00:00Z',
    };
}

1;
