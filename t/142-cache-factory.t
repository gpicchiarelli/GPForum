# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Service::Operations::CacheFactory;
use GPForum::Service::Operations::LocalCache;
use GPForum::Service::Operations::TieredCache;
use Test::Exception;
use Test::More;

our $VERSION = '0.001';

my $tiered =
  GPForum::Service::Operations::CacheFactory->build( GPForum::Config->new );
isa_ok(
    $tiered,
    'GPForum::Service::Operations::TieredCache',
    'default config wires GlifiStore behind a tiered cache'
);

my $local = GPForum::Service::Operations::CacheFactory->build(
    GPForum::Config->new( glifistore_url => q{} ) );
isa_ok(
    $local,
    'GPForum::Service::Operations::LocalCache',
    'development may keep process-local L1 when GlifiStore is unset'
);

throws_ok(
    sub {
        GPForum::Service::Operations::CacheFactory->build(
            GPForum::Config->new(
                environment    => 'production-small',
                glifistore_url => q{},
                session_secret => 'rotated-production-secret',
            )
        );
    },
    qr/\A glifistore_url [ ] is [ ] required/msx,
    'production fails closed when GlifiStore is missing',
);

my $production = GPForum::Service::Operations::CacheFactory->build(
    GPForum::Config->new(
        environment    => 'production-small',
        glifistore_url => 'tcp://127.0.0.1:1',
        session_secret => 'rotated-production-secret',
    )
);
isa_ok(
    $production,
    'GPForum::Service::Operations::TieredCache',
    'production still wires L2 when GlifiStore is unreachable'
);

done_testing();

1;
