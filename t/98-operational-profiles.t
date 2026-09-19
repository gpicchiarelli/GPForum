package main;

use strict;
use warnings;

use lib 'lib';

use Const::Fast;
use GPForum::Config;
use GPForum::Service::Operations::Profile;
use Test::More;

our $VERSION = '0.001';

const my $SMALL_CACHE     => 2_048;
const my $SMALL_WEB       => 4;
const my $PROFILE_VERSION => 1;

my $profiles = GPForum::Service::Operations::Profile->new;
is_deeply(
    $profiles->names,
    [ 'development', 'production-medium', 'production-small', 'staging' ],
    'canonical operational profiles are versioned'
);
is( $profiles->name_for_environment('production'),
    'production-small', 'production maps onto production-small' );
is( $profiles->name_for_environment('test'),
    'development', 'test maps onto development' );
is( $profiles->get('staging')->{version},
    $PROFILE_VERSION, 'staging profile is versioned' );

my $development = $profiles->evaluate( GPForum::Config->new );
ok( $development->{ok}, 'default config meets the development profile' );
is( $development->{profile}{name},
    'development', 'default environment selects development' );

my $too_small = $profiles->evaluate(
    GPForum::Config->new(
        environment             => 'production-medium',
        session_secret          => 'rotated-production-secret',
        web_processes           => $SMALL_WEB,
        worker_processes        => 2,
        realtime_processes      => 1,
        local_cache_max_entries => $SMALL_CACHE,
    )
);
ok( !$too_small->{ok},
    'production-medium rejects process counts below its floor' );
ok( $too_small->{errors}{web_processes},
    'production-medium names the web process floor' );

my $rotated = $profiles->evaluate(
    GPForum::Config->new(
        environment    => 'production-small',
        session_secret => 'rotated-production-secret',
    )
);
ok( $rotated->{ok},
    'production-small accepts default sizing with a rotated secret' );
ok(
    $rotated->{profile}{requires_glifistore},
    'production-small requires GlifiStore'
);

my $missing_l2 = $profiles->evaluate(
    GPForum::Config->new(
        environment    => 'production-small',
        glifistore_url => q{},
        session_secret => 'rotated-production-secret',
    )
);
ok( !$missing_l2->{ok}, 'production-small rejects a missing GlifiStore URL' );
ok( $missing_l2->{errors}{glifistore_url},
    'production-small names the GlifiStore requirement' );

my $unknown =
  $profiles->evaluate( GPForum::Config->new( environment => 'lab' ) );
ok( !$unknown->{ok}, 'unknown environments are rejected' );

done_testing();

1;
