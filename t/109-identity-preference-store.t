# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

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
my $locale_updated_at = $schema->users->[0]{updated_at};
$clock->iso8601('2026-05-23T13:00:00Z');
my $locale_again = $store->update_preferred_locale(
    {
        preferred_locale => 'it',
        user_id          => 'user-1',
    }
);
ok( $locale_again->{skipped},
    'update_preferred_locale skips an unchanged locale' );
is( $schema->users->[0]{preferred_locale},
    'it', 'unchanged locale stays persisted' );
is( $schema->users->[0]{updated_at},
    $locale_updated_at, 'unchanged locale does not restamp updated_at' );

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
my $theme_updated_at = $schema->users->[0]{updated_at};
$clock->iso8601('2026-05-23T14:00:00Z');
my $theme_again = $store->update_preferred_theme(
    {
        preferred_theme => 'high_contrast',
        user_id         => 'user-1',
    }
);
ok( $theme_again->{skipped},
    'update_preferred_theme skips an unchanged theme' );

is( $schema->users->[0]{preferred_theme},
    'high_contrast', 'unchanged theme stays persisted' );
is( $schema->users->[0]{updated_at},
    $theme_updated_at, 'unchanged theme does not restamp updated_at' );

my $missing_theme = $store->update_preferred_theme(
    {
        preferred_theme => q{},
        user_id         => 'user-1',
    }
);
is( $missing_theme->{error},
    'theme_required', 'update_preferred_theme rejects an empty theme' );

# 9.3: a zone is an IANA name, or empty for the forum's default (NULL).
my $zone = $store->update_preferred_timezone(
    { preferred_timezone => 'Europe/Rome', user_id => 'user-1' } );
ok( $zone->{ok}, 'update_preferred_timezone stores a known zone' );
is( $schema->users->[0]{preferred_timezone}, 'Europe/Rome', 'on the user row' );
ok(
    $store->update_preferred_timezone(
        { preferred_timezone => 'Europe/Rome', user_id => 'user-1' }
    )->{skipped},
    'and skips an unchanged one'
);
is(
    $store->update_preferred_timezone(
        { preferred_timezone => 'Mars/Olympus_Mons', user_id => 'user-1' }
    )->{error},
    'timezone_invalid',
    'refuses a name the time zone database does not know'
);
is( $schema->users->[0]{preferred_timezone},
    'Europe/Rome', 'leaving the stored zone alone' );
ok(
    $store->update_preferred_timezone(
        { preferred_timezone => q{}, user_id => 'user-1' }
    )->{ok},
    'an empty zone is the forum default'
);
is( $schema->users->[0]{preferred_timezone},
    undef, 'stored as NULL, so the member follows the default' );

done_testing();

1;
