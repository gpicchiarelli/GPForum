package main;

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::RequestPreferenceController;
use GPForum::Web::RequestPreference;

our $VERSION = '0.001';

my $preference = GPForum::Web::RequestPreference->new;

is(
    $preference->wants_json(
        GPForum::Test::RequestPreferenceController->new( format => 'json' )
    ),
    1,
    'format=json requests JSON'
);

is(
    $preference->wants_json(
        GPForum::Test::RequestPreferenceController->new(
            accept_header => 'application/json'
        )
    ),
    1,
    'application/json accept requests JSON'
);

is(
    $preference->wants_json(
        GPForum::Test::RequestPreferenceController->new(
            accept_header => 'text/html, application/json'
        )
    ),
    1,
    'combined accept header requests JSON when application/json is present'
);

is(
    $preference->wants_json(
        GPForum::Test::RequestPreferenceController->new(
            format        => 'html',
            accept_header => 'text/html',
        )
    ),
    0,
    'HTML format and accept does not request JSON'
);

is(
    $preference->wants_json(
        GPForum::Test::RequestPreferenceController->new()
    ),
    0,
    'missing format and accept does not request JSON'
);

done_testing();

1;
