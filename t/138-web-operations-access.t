package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Web::OperationsAccess;
use Test::More;

our $VERSION = '0.001';

const my $HTTP_UNAUTHORIZED => 401;
const my $TOKEN             => 'metrics-secret';
const my $OTHER_TOKEN       => 'metrics-secreX';

my $access = GPForum::Web::OperationsAccess->new;

is( $access->metrics_token_header,
    'X-GPForum-Metrics-Token', 'metrics_token_header keeps the scrape header' );

ok(
    $access->metrics_authorized(
        {
            authorization    => q{},
            configured_token => q{},
            metrics_header   => q{},
        }
    ),
    'metrics_authorized allows an unconfigured token'
);
ok(
    $access->metrics_authorized(
        {
            authorization    => q{},
            configured_token => undef,
            metrics_header   => q{},
        }
    ),
    'metrics_authorized allows a missing token'
);

ok(
    $access->metrics_authorized(
        {
            authorization    => "Bearer $TOKEN",
            configured_token => $TOKEN,
            metrics_header   => q{},
        }
    ),
    'metrics_authorized accepts a matching Bearer token'
);
ok(
    $access->metrics_authorized(
        {
            authorization    => q{},
            configured_token => $TOKEN,
            metrics_header   => $TOKEN,
        }
    ),
    'metrics_authorized accepts a matching metrics header'
);

ok(
    !$access->metrics_authorized(
        {
            authorization    => q{},
            configured_token => $TOKEN,
            metrics_header   => q{},
        }
    ),
    'metrics_authorized rejects a missing scrape token'
);
ok(
    !$access->metrics_authorized(
        {
            authorization    => "Bearer $OTHER_TOKEN",
            configured_token => $TOKEN,
            metrics_header   => q{},
        }
    ),
    'metrics_authorized rejects a same-length Bearer mismatch'
);
ok(
    !$access->metrics_authorized(
        {
            authorization    => 'Bearer short',
            configured_token => $TOKEN,
            metrics_header   => q{},
        }
    ),
    'metrics_authorized rejects a length-mismatched Bearer token'
);

is_deeply(
    $access->unauthorized_payload,
    {
        json => {
            error  => 'metrics token required',
            status => 'unauthorized',
        },
        status => $HTTP_UNAUTHORIZED,
    },
    'unauthorized_payload keeps the metrics 401 contract'
);

done_testing();

1;
