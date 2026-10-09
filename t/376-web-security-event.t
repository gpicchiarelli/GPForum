# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Mojolicious;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Operations::SecurityTelemetry;
use GPForum::Test::RoutelessController;
use GPForum::Web::ErrorPayload;
use GPForum::Web::SecurityEvent;

our $VERSION = '0.001';

const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_TOO_MANY     => 429;
const my $JSON              => { Accept => 'application/json' };

# Each refusal records its event, with the route the request matched, and
# then renders the same error the controllers rendered through Guard.

my $telemetry = GPForum::Service::Operations::SecurityTelemetry->new;
my $app       = Mojolicious->new;
$app->log->level('fatal');
$app->helper( gp_security_telemetry => sub { return $telemetry; } );
my $routes = $app->routes;
for my $refusal (qw(csrf_failure unauthorized forbidden rate_limited)) {
    $routes->get(
        "/$refusal" => sub ($controller) {
            return GPForum::Web::SecurityEvent->new->$refusal($controller);
        } => "probe_$refusal"
    );
}
$routes->get(
    '/forbidden_because' => sub ($controller) {
        return GPForum::Web::SecurityEvent->new->forbidden( $controller,
            { error => 'user is suspended' } );
    } => 'probe_forbidden_because'
);
my $test = Test::Mojo->new($app);

my @cases = (
    [
        csrf_failure => $HTTP_FORBIDDEN,
        GPForum::Web::ErrorPayload->csrf_failure,
        csrf_failure => { status => $HTTP_FORBIDDEN },
    ],
    [
        unauthorized => $HTTP_UNAUTHORIZED,
        GPForum::Web::ErrorPayload->unauthorized,
        auth_denial => { status => $HTTP_UNAUTHORIZED },
    ],
    [
        forbidden => $HTTP_FORBIDDEN,
        GPForum::Web::ErrorPayload->forbidden,
        auth_denial => { reason => 'forbidden', status => $HTTP_FORBIDDEN },
    ],
    [
        forbidden_because => $HTTP_FORBIDDEN,
        GPForum::Web::ErrorPayload->forbidden( error => 'user is suspended' ),
        auth_denial => { reason => 'forbidden', status => $HTTP_FORBIDDEN },
    ],
    [
        rate_limited => $HTTP_TOO_MANY,
        GPForum::Web::ErrorPayload->rate_limited,
        rate_limit_hit => { status => $HTTP_TOO_MANY },
    ],
);
for my $case (@cases) {
    my ( $path, $status, $payload, $event, $metadata ) = @{$case};
    subtest "$path records $event and renders $status" => sub {
        my $before = _count($event);
        $test->get_ok( "/$path" => $JSON )
          ->status_is($status)
          ->json_is( q{} => $payload );
        is( _count($event), $before + 1, "one $event recorded" );
        is_deeply(
            $telemetry->events->{$event}{last_metadata},
            { %{$metadata}, route => "probe_$path" },
            'with the status and the route the request matched'
        );
    };
}

subtest 'a controller with no route to name records the route unknown' => sub {
    my $routeless = GPForum::Service::Operations::SecurityTelemetry->new;
    my $recorded =
      GPForum::Web::SecurityEvent->new->record_event(
        GPForum::Test::RoutelessController->new( telemetry => $routeless ),
        'suspended_user_block', { action => 'post.create', status => 403 } );

    is( $recorded->{event_type},
        'suspended_user_block', 'returns what the telemetry recorded' );
    is_deeply(
        $routeless->events->{suspended_user_block}{last_metadata},
        { action => 'post.create', route => 'unknown', status => 403 },
        'the route is unknown, the metadata kept'
    );
};

done_testing();

sub _count ($event) {
    my $recorded = $telemetry->events->{$event};

    return $recorded ? $recorded->{count} : 0;
}

1;
