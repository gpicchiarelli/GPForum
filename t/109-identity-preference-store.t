package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Identity::PreferenceStore;
use GPForum::Test::FixedClock;
use GPForum::Test::Schema;
use Test::More;

our $VERSION = '0.001';

my $clock  = GPForum::Test::FixedClock->new;
my $schema = GPForum::Test::Schema->new(
    users => [
        {
            id               => 'user-1',
            preferred_locale => 'en',
            preferred_theme  => 'default',
            status           => 'active',
        },
    ],
);
my $store = GPForum::Service::Identity::PreferenceStore->new(
    clock  => $clock,
    schema => $schema,
);

my $locale = $store->preferred_locale_for_user( { user_id => 'user-1' } );
ok( $locale->{ok}, 'preferred_locale_for_user succeeds for a known user' );
is( $locale->{preferred_locale},
    'en', 'preferred_locale_for_user returns the stored locale' );

my $updated_locale = $store->update_preferred_locale(
    {
        preferred_locale => 'it',
        user_id          => 'user-1',
    }
);
ok( $updated_locale->{ok}, 'update_preferred_locale succeeds' );
is( $updated_locale->{preferred_locale},
    'it', 'update_preferred_locale returns the new locale' );
is( $schema->users->[0]{preferred_locale},
    'it', 'update_preferred_locale persists the locale' );
is( $schema->users->[0]{updated_at},
    $clock->now_iso8601, 'update_preferred_locale refreshes updated_at' );

my $missing_locale = $store->update_preferred_locale(
    {
        preferred_locale => q{},
        user_id          => 'user-1',
    }
);
is( $missing_locale->{error},
    'locale_required', 'update_preferred_locale rejects an empty locale' );

my $missing_user = $store->update_preferred_locale(
    {
        preferred_locale => 'it',
        user_id          => 'missing',
    }
);
is( $missing_user->{error},
    'not_found', 'update_preferred_locale maps a missing user to not_found' );

my $theme = $store->update_preferred_theme(
    {
        preferred_theme => 'high_contrast',
        user_id         => 'user-1',
    }
);
ok( $theme->{ok}, 'update_preferred_theme succeeds' );
is( $theme->{preferred_theme},
    'high_contrast', 'update_preferred_theme returns the new theme' );
is(
    $store->preferred_theme_for_user( { user_id => 'user-1' } )
      ->{preferred_theme},
    'high_contrast',
    'preferred_theme_for_user reads the stored theme'
);

my $missing_theme = $store->update_preferred_theme(
    {
        preferred_theme => q{},
        user_id         => 'user-1',
    }
);
is( $missing_theme->{error},
    'theme_required', 'update_preferred_theme rejects an empty theme' );

done_testing();

1;
