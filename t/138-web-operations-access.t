# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Config;
use GPForum::Web::OperationsAccess;
use Mojo::Headers;
use Test::Exception;
use Test::More;

our $VERSION = '0.001';

const my $HTTP_UNAUTHORIZED => 401;
const my $TOKEN             => 'metrics-secret';
const my $OTHER_TOKEN       => 'metrics-secreX';
const my $PREVIOUS_TOKEN    => 'previous-metrics';
const my $GLIFISTORE_URL    => 'tcp://127.0.0.1:7379';

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

ok(
    $access->metrics_authorized(
        {
            accepted_tokens  => [ $TOKEN, $PREVIOUS_TOKEN ],
            authorization    => q{},
            configured_token => $TOKEN,
            metrics_header   => $PREVIOUS_TOKEN,
        }
    ),
    'metrics_authorized accepts a previous metrics header'
);
ok(
    !$access->metrics_authorized(
        {
            accepted_tokens  => [ $TOKEN, $PREVIOUS_TOKEN ],
            authorization    => q{},
            configured_token => $TOKEN,
            metrics_header   => $OTHER_TOKEN,
        }
    ),
    'metrics_authorized rejects a token outside the accepted list'
);

throws_ok(
    sub {
        GPForum::Config->new(
            environment    => 'production',
            glifistore_url => $GLIFISTORE_URL,
            metrics_token  => q{},
            session_secret => 'rotated-production-secret',
        )->validate;
    },
    qr/\A production [ ] requires [ ] GPFORUM_METRICS_TOKEN/msx,
    'production configuration cannot leave the metrics token unconfigured',
);
is( GPForum::Config->new->validate->metrics_token,
    q{}, 'development may leave the metrics token unconfigured and fail open' );

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

# The headers and config the controllers pass in: /metrics, /health and
# /health/ready read the token from the same two headers and rotation list.
my $rotating = GPForum::Config->new(
    metrics_token           => $TOKEN,
    previous_metrics_tokens => [$PREVIOUS_TOKEN],
);
is_deeply(
    $access->metrics_input( Mojo::Headers->new, $rotating ),
    {
        authorization    => q{},
        configured_token => $TOKEN,
        accepted_tokens  => [ $TOKEN, $PREVIOUS_TOKEN ],
        metrics_header   => q{},
    },
    'metrics_input reads absent headers as empty strings'
);
ok(
    !$access->request_authorized( Mojo::Headers->new, $rotating ),
    'request_authorized rejects a request without a token'
);
ok(
    $access->request_authorized(
        Mojo::Headers->new->authorization("Bearer $TOKEN"), $rotating
    ),
    'request_authorized accepts the Bearer token'
);
ok(
    $access->request_authorized(
        Mojo::Headers->new->header(
            'X-GPForum-Metrics-Token' => $PREVIOUS_TOKEN
        ),
        $rotating
    ),
    'request_authorized accepts a previous token in the metrics header'
);
ok(
    !$access->request_authorized(
        Mojo::Headers->new->header( 'X-GPForum-Metrics-Token' => $OTHER_TOKEN ),
        $rotating
    ),
    'request_authorized rejects a wrong token'
);
ok(
    $access->request_authorized( Mojo::Headers->new, GPForum::Config->new ),
    'request_authorized is open when no token is configured'
);

done_testing();

1;
