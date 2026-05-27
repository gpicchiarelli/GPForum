package GPForum::Test::ReadinessRuntime;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub as_hash {
    return {
        mode => 'test',
        os   => {
            name                     => 'test',
            event_backend            => 'test',
            cpu_count                => 1,
            recommended_worker_count => 1,
            resources                => {
                open_file_descriptors => 1,
            },
        },
        os_sockets => {
            reuseaddr => {
                enabled  => 1,
                degraded => 0,
            },
        },
        os_processes => {
            classes => {
                web_worker => {
                    known => 1,
                },
            },
        },
    };
}

sub os_preflight_settings {
    return {};
}

1;
