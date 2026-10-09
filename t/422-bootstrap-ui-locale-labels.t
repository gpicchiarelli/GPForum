# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Mojolicious;
use Test::More;

use lib 'lib';

use GPForum::Bootstrap::UI;
use GPForum::Service::I18N;

our $VERSION = '0.001';

# Two presentation helpers of Bootstrap::UI: the locale switcher's options,
# and the label key a free-form value is looked up under.

my $application = Mojolicious->new;
GPForum::Bootstrap::UI->register(
    application => $application,
    i18n        => GPForum::Service::I18N->new,
);

my $italian = $application->build_controller;
$italian->stash( ui_locale => 'it' );

is_deeply(
    $italian->ui_locale_options,
    [
        { current => 0, locale => 'en', native_name => 'English' },
        { current => 1, locale => 'it', native_name => 'Italiano' },
    ],
    'one option per locale, named in its own language, the current one marked'
);

my $english = $application->build_controller;
$english->stash( ui_locale => 'en' );

is( $english->ui_label( 'state', 'Not Run!' ),
    'Not run', 'a label key folds case and punctuation to underscores' );
is( $english->ui_label( 'state', 'not.run' ),
    'Not run', 'a dot is punctuation too, not a key separator' );
is(
    $english->ui_label(
        'state', "not run \N{LATIN SMALL LETTER E WITH ACUTE}"
    ),
    'Not run',
    'and a key fragment is ASCII letters and digits only'
);
is( $english->ui_label( 'state', 'Mystery' ),
    'Mystery', 'a value with no label is shown as it is' );

done_testing();

1;
