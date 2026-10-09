# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Mojo::Transaction::HTTP;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Controller::Admin::Base;
use GPForum::Controller::Moderation::Base;
use GPForum::Controller::Privacy::Base;
use GPForum::Test::AllowPermissionGate;
use GPForum::Test::DenyPermissionGate;
use GPForum::Test::RecordingLimiter;

our $VERSION = '0.001';

const my $HTTP_FOUND               => 302;
const my $HTTP_BAD_REQUEST         => 400;
const my $HTTP_FORBIDDEN           => 403;
const my $HTTP_NOT_FOUND           => 404;
const my $HTTP_CONFLICT            => 409;
const my $HTTP_SERVICE_UNAVAILABLE => 503;
const my $MEMBER                   => 'user-1';
const my $REQUEST_ID               => '018f1000-0000-7000-8000-0000000000b2';

# The admin, moderation and privacy controller bases fold their refusals into
# the method that meets them. These pins hold what each base answers when a
# write fails, which limiter action it asks for, and that a refused
# permission is logged, so a fold that drops or swaps one of them fails here.

my %double = (
    gate    => GPForum::Test::AllowPermissionGate->new,
    limiter => GPForum::Test::RecordingLimiter->new,
);
my $test = Test::Mojo->new('GPForum');
my $app  = $test->app;
$app->log->level(q{fatal});
$app->helper( gp_permission_gate => sub { return $double{gate}; } );
$app->helper( gp_rate_limiter    => sub { return $double{limiter}; } );

my @KEEP_ALIVE;

my %CONFLICT = (
    Admin => {
        given   => { error => 'already bound',        status => 'conflict' },
        default => { error => 'idempotency conflict', status => 'conflict' },
        title   => 'Conflict',
    },
    Moderation => {
        given   => { error => 'already bound',        status => 'conflict' },
        default => { error => 'idempotency conflict', status => 'conflict' },
        title   => 'Conflict',
    },
    Privacy => {
        given   => { error => 'already bound', status => 'blocked' },
        default => { error => 'conflict',      status => 'blocked' },
        title   => 'Privacy action blocked',
    },
);

for my $family ( sort keys %CONFLICT ) {
    subtest "$family write failures" => sub {
        _write_failures_ok( $family, $CONFLICT{$family} );
    };
}

subtest 'each write asks the limiter for its own action' => sub {
    my %writes = (
        'admin.write' => sub {
            return _controller('Admin')->authorized_write_user_id;
        },
        'moderation.write' => sub {
            return _controller('Moderation')
              ->authorized_write_user_id( 'report', 'assign' );
        },
        'privacy.request' => sub {
            return _controller('Privacy')->write_user_id;
        },
        'privacy.review' => sub {
            return _controller('Privacy')->authorized_write_user_id;
        },
    );
    for my $action ( sort keys %writes ) {
        $double{limiter} = GPForum::Test::RecordingLimiter->new;
        is( $writes{$action}->(), $MEMBER, "$action lets the member write" );
        my ($check) = @{ $double{limiter}->checks };
        is_deeply(
            [ @{ $check || {} }{qw(action actor_id)} ],
            [ $action, $MEMBER ],
            "$action is the action the limiter counts, for the member"
        );
    }
};

subtest 'a refused permission is logged before the 403' => sub {
    $double{gate} = GPForum::Test::DenyPermissionGate->new;
    my %refusals = (
        Moderation => sub ($controller) {
            return $controller->authorized_user_id('view');
        },
        Privacy => sub ($controller) {
            return $controller->authorized_user_id('manage');
        },
    );
    for my $family ( sort keys %refusals ) {
        my $controller = _controller($family);
        my @denials    = _denials_logged(
            sub {
                ok(
                    !$refusals{$family}->($controller),
                    "$family refuses the member"
                );
            }
        );
        is( $controller->res->code, $HTTP_FORBIDDEN, "$family answers 403" );
        like(
            $denials[0] // q{},
            qr/\A permission [ ] denied: [ ] user [ ] user-1 [ ] lacks [ ]/msx,
            "$family logs the permission it refused"
        );
    }
    $double{gate} = GPForum::Test::AllowPermissionGate->new;
};

subtest 'a privacy action redirects where its caller asked' => sub {
    my $controller = _controller( 'Privacy', html => 1 );
    $controller->privacy_action_response( { status => 'deletion_approved' },
        'privacy_review' );
    is( $controller->res->code, $HTTP_FOUND, 'the HTML answer redirects' );
    is(
        $controller->res->headers->location,
        $controller->url_for('privacy_review')->to_string,
        'to the route the caller named'
    );

    my $default = _controller( 'Privacy', html => 1 );
    $default->privacy_action_response( { status => 'export_requested' } );
    is(
        $default->res->headers->location,
        $default->url_for('privacy_dashboard')->to_string,
        'and to the privacy dashboard when it named none'
    );
};

subtest 'an export download without a manifest sends an empty object' => sub {
    my $controller = _controller('Privacy');
    $controller->render_export_download( { export_request_id => $REQUEST_ID } );
    is_deeply( $controller->res->json, {}, 'the body is an empty object' );
    like(
        $controller->res->headers->content_disposition // q{},
        qr/\A attachment; [ ] filename=/msx,
        'sent as a download'
    );

    my $exported = _controller('Privacy');
    $exported->render_export_download(
        {
            export_request_id => $REQUEST_ID,
            manifest          => { posts => [] },
        }
    );
    is_deeply(
        $exported->res->json,
        { posts => [] },
        'a manifest is sent as it was stored'
    );
};

done_testing();

sub _write_failures_ok ( $family, $conflict ) {
    my $succeeded = _controller($family);
    ok( !defined $succeeded->write_failure( { status => 'ok' } ),
        'a write that did not fail answers undef' );
    ok( !$succeeded->res->code, 'and renders nothing' );

    my $failed = _controller($family);
    $failed->write_failure( { status => 'failed' } );
    is( $failed->res->code, $HTTP_SERVICE_UNAVAILABLE,
        'a failed write answers 503' );

    my $missing = _controller($family);
    $missing->write_failure(
        { status => 'not_found', error => 'role 7 not found' } );
    is( $missing->res->code, $HTTP_NOT_FOUND, 'a missing target answers 404' );
    is(
        $missing->res->json->{error},
        'role 7 not found',
        'naming what was not found'
    );

    my $invalid = _controller($family);
    $invalid->write_failure(
        { status => 'invalid', errors => { name => 'name is required' } } );
    is( $invalid->res->code, $HTTP_BAD_REQUEST,
        'an invalid write answers 400' );
    is_deeply(
        $invalid->res->json->{errors},
        { name => 'name is required' },
        'with the fields it refused'
    );

    for my $case (qw(given default)) {
        my $result = { status => 'conflict' };
        if ( $case eq 'given' ) {
            $result->{error} = 'already bound';
        }
        my $conflicted = _controller($family);
        $conflicted->write_failure($result);
        is( $conflicted->res->code,
            $HTTP_CONFLICT, "a conflict ($case error) answers 409" );
        is_deeply(
            $conflicted->res->json,
            { %{ $conflict->{$case} }, title => $conflict->{title} },
            "with its $case error and title"
        );
    }

    return;
}

# A controller of the family's base on a fresh request, signed in as the
# member, carrying a valid CSRF token and asking for JSON unless html is set.
sub _controller ( $family, %options ) {
    my $tx         = Mojo::Transaction::HTTP->new;
    my $class      = "GPForum::Controller::${family}::Base";
    my $controller = $class->new( app => $app, tx => $tx );
    push @KEEP_ALIVE, $tx, $controller;
    $controller->session( user_id => $MEMBER );
    my $headers = $tx->req->headers;
    $headers->header( 'X-CSRF-Token' => $controller->csrf_token );
    if ( !$options{html} ) {
        $headers->accept('application/json');
    }

    return $controller;
}

sub _denials_logged ($code) {
    my @denials;
    my $log      = $app->log;
    my $level    = $log->level;
    my $listener = $log->on(
        message => sub ( $, $, @lines ) {
            push @denials, grep { /\A permission [ ] denied/msx } @lines;
        }
    );
    $log->level('info');
    $code->();
    $log->unsubscribe( message => $listener );
    $log->level($level);

    return @denials;
}

1;
