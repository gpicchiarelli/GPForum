# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::Config;
use GPForum::Service::Operations::CacheFactory;
use GPForum::Service::Operations::Profile;

our $VERSION = '0.001';

const my $LARGEST_FLOOR => 4_096;
const my %DEPLOYED => (
    GPFORUM_SESSION_SECRET  => 'a' x 64,
    GPFORUM_METRICS_TOKEN   => 'b' x 32,
    GPFORUM_PUBLIC_BASE_URL => 'https://forum.gpforum.test',
    GPFORUM_MAIL_FROM       => 'forum@forum.gpforum.test',
);

# GPFORUM_ENV=production-medium failed readiness out of the box: its local
# cache floor was 4096 entries and the default 2048 (iteration-1 reviews,
# walkthrough 1, friction 16). An operator who changed nothing was told a
# setting was below a floor. The default now meets every profile's floor.
# And CacheFactory still carried a "fail closed" branch for a deployed
# profile without GlifiStore, which nothing could reach since GlifiStore
# became optional everywhere (D2).

subtest 'the default cache meets every profile' => sub {
    is( GPForum::Config->new->local_cache_max_entries,
        $LARGEST_FLOOR, 'GPFORUM_LOCAL_CACHE_MAX_ENTRIES defaults to 4096' );
    my $profiles = GPForum::Service::Operations::Profile->new;
    my $default  = GPForum::Config->new->local_cache_max_entries;
    for my $name ( @{ $profiles->names } ) {
        cmp_ok( $profiles->get($name)->{local_cache_max_entries},
            '<=', $default, "$name: the cache floor is at most the default" );
    }

    for my $environment (
        qw(development test staging production production-small
        production-medium)
      )
    {
        my $config = GPForum::Config->from_environment(
            { %DEPLOYED, GPFORUM_ENV => $environment } );
        ok(
            !exists $profiles->evaluate($config)
              ->{errors}{local_cache_max_entries},
            "$environment: the default cache is no readiness error"
        );
    }
};

subtest 'without GlifiStore the cache is local, whatever is asked' => sub {
    my $insistent = GPForum::Config->new(
        environment    => 'production',
        glifistore_url => q{},
    );
    no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings) -- a configuration that still claims to need GlifiStore
    local *GPForum::Config::requires_glifistore = sub { return 1 };
    isa_ok(
        GPForum::Service::Operations::CacheFactory->build($insistent),
        'GPForum::Service::Operations::LocalCache',
        'a configuration that claims to need GlifiStore still gets L1, no throw'
    );

    my $source = path('lib/GPForum/Service/Operations/CacheFactory.pm')->slurp;
    unlike(
        $source,
        qr/fail [ ] closed/msxi,
        'and nothing in CacheFactory says it fails closed'
    );
    unlike(
        $source,
        qr/requires_glifistore|X::Config/msx,
        'nor asks whether GlifiStore is required'
    );
};

done_testing();

1;
