package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use File::Temp qw(tempdir);
use JSON::MaybeXS qw(decode_json);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::Command::StagingHostVerify;
use GPForum::Service::Operations::StagingHostVerify;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 45;

plan tests => $EXPECTED_TESTS;

_test_prerequisites_only();
_test_env_file_keys();
_test_metrics_header();
_test_tls_observe();
_test_unit_files_observe();
_test_nginx_conf_observe();
_test_command_help();
_test_command_unknown();
_test_command_json();

sub _test_prerequisites_only {
    my $evidence =
      GPForum::Service::Operations::StagingHostVerify->new->run( {} );
    is( $evidence->{status}, 'pass', 'prerequisites-only verify passes' );
    is( $evidence->{prerequisites}{status},
        'pass', 'prerequisites phase passes' );
    is( $evidence->{env_file}{status}, 'skipped', 'env_file skipped by default' );
    is( $evidence->{systemd}{status},  'skipped', 'systemd skipped by default' );
    is( $evidence->{unit_files}{status},
        'skipped', 'unit_files skipped by default' );
    is( $evidence->{nginx_conf}{status},
        'skipped', 'nginx_conf skipped by default' );
    is( $evidence->{health}{status}, 'skipped', 'health skipped by default' );
    is( $evidence->{tls}{status},    'skipped', 'tls skipped without base-url' );
    ok( @{ $evidence->{residual_gaps} } >= 1,
        'residual gaps note live staging evidence' );
    ok( $evidence->{secrets_redacted},
        'verify evidence marks secrets_redacted' );
    is( $evidence->{private_beta_claimed}, 0,
        'verify evidence refuses private-beta claim' );

    return;
}

sub _test_env_file_keys {
    my $dir  = tempdir( CLEANUP => 1 );
    my $path = path( $dir, 'gpforum.env' )->to_string;
    path($path)->spew(<<'ENV');
GPFORUM_SESSION_SECRET=not-a-real-secret
GPFORUM_DATABASE_DSN=dbi:Pg:dbname=gpforum
GPFORUM_DATABASE_USER=gpforum
GPFORUM_METRICS_TOKEN=metrics-token
# comment
EMPTY=
ENV

    my $evidence = GPForum::Service::Operations::StagingHostVerify->new->run(
        { env_file => $path } );
    is( $evidence->{env_file}{status}, 'pass', 'env file with keys passes' );
    is_deeply(
        $evidence->{env_file}{missing_keys},
        [],
        'no missing required keys'
    );
    ok( $evidence->{env_file}{values_redacted},
        'env evidence marks values redacted' );

    my $bad = path( $dir, 'incomplete.env' )->to_string;
    path($bad)->spew("GPFORUM_SESSION_SECRET=only-one\n");
    my $fail = GPForum::Service::Operations::StagingHostVerify->new->run(
        { env_file => $bad } );
    is( $fail->{env_file}{status}, 'fail', 'incomplete env file fails phase' );
    is( $fail->{status},           'fail', 'incomplete env fails overall' );

    return;
}

sub _test_metrics_header {
    my $src = path('lib/GPForum/Service/Operations/StagingHostVerify.pm')->slurp;
    like(
        $src,
        qr/X-GPForum-Metrics-Token/msx,
        'metrics probe uses X-GPForum-Metrics-Token'
    );
    unlike(
        $src,
        qr/X-Metrics-Token(?![A-Za-z-])/msx,
        'metrics probe does not use the wrong X-Metrics-Token header'
    );

    return;
}

sub _test_tls_observe {
    my $http = GPForum::Service::Operations::StagingHostVerify->new->run(
        { base_url => 'http://127.0.0.1:9', timeout => 1 } );
    is( $http->{tls}{status}, 'skipped', 'http base-url skips TLS pass' );
    is( $http->{tls}{scheme}, 'http',    'http scheme recorded' );
    is( $http->{tls}{port},   9,         'http port parsed from base-url' );
    ok( @{ $http->{tls}{residual_gaps} // [] } >= 1,
        'http base-url residual asks for https evidence' );

    my $https = GPForum::Service::Operations::StagingHostVerify->new->run(
        { base_url => 'https://staging.example:8443/', timeout => 1 } );
    is( $https->{tls}{status}, 'pass',  'https base-url tls observe passes' );
    is( $https->{tls}{scheme}, 'https', 'https scheme recorded' );
    is( $https->{tls}{host}, 'staging.example', 'https host parsed' );
    is( $https->{tls}{port}, 8443, 'https port parsed' );

    like(
        path('lib/GPForum/Service/Operations/StagingHostVerify.pm')->slurp,
        qr/_tls_phase|_parse_base_url/msx,
        'service defines tls observe helpers'
    );

    return;
}

sub _test_unit_files_observe {
    my $dir = tempdir( CLEANUP => 1 );
    path( $dir, 'gpforum.service' )->spew(<<'UNIT');
[Service]
User=gpforum
EnvironmentFile=/etc/gpforum/gpforum.env
ExecStart=/srv/gpforum/script/gpforum-carton exec hypnotoad /srv/gpforum/bin/gpforum
UNIT
    path( $dir, 'gpforum-outbox.service' )->spew(<<'UNIT');
[Service]
User=gpforum
EnvironmentFile=/etc/gpforum/gpforum.env
ExecStart=/srv/gpforum/script/gpforum-carton exec bin/gpforum-outbox-dispatch
UNIT
    path( $dir, 'gpforum-scheduled-jobs.service' )->spew(<<'UNIT');
[Service]
User=gpforum
EnvironmentFile=/etc/gpforum/gpforum.env
ExecStart=/srv/gpforum/script/gpforum-carton exec bin/gpforum-scheduled-jobs --once
UNIT

    my $pass = GPForum::Service::Operations::StagingHostVerify->new->run(
        { unit_dir => $dir } );
    is( $pass->{unit_files}{status}, 'pass', 'matching unit contracts pass' );
    is( $pass->{status}, 'pass', 'overall pass with unit_dir only' );

    path( $dir, 'gpforum.service' )->spew("User=root\n");
    my $fail = GPForum::Service::Operations::StagingHostVerify->new->run(
        { unit_dir => $dir } );
    is( $fail->{unit_files}{status}, 'fail', 'broken unit contract fails' );
    is( $fail->{status},             'fail', 'overall fail on unit contract' );

    my $missing = GPForum::Service::Operations::StagingHostVerify->new->run(
        { unit_dir => path( $dir, 'missing' )->to_string } );
    is( $missing->{unit_files}{status},
        'fail', 'missing unit directory fails phase' );

    return;
}

sub _test_nginx_conf_observe {
    my $dir  = tempdir( CLEANUP => 1 );
    my $path = path( $dir, 'gpforum.conf' )->to_string;
    path($path)->spew( path('deploy/nginx/gpforum.conf')->slurp );

    my $pass = GPForum::Service::Operations::StagingHostVerify->new->run(
        { nginx_conf => $path } );
    is( $pass->{nginx_conf}{status}, 'pass', 'matching nginx conf passes' );
    is( $pass->{nginx_conf}{matched_profile},
        'gpforum.conf', 'tcp nginx profile matched' );

    path($path)->spew("server { listen 80; }\n");
    my $fail = GPForum::Service::Operations::StagingHostVerify->new->run(
        { nginx_conf => $path } );
    is( $fail->{nginx_conf}{status}, 'fail', 'non-contract nginx conf fails' );
    is( $fail->{status},             'fail', 'overall fail on nginx conf' );

    return;
}

sub _test_command_help {
    my $command = GPForum::Command::StagingHostVerify->new;
    my $usage   = q{};
    {
        open my $stdout, '>', \$usage or croak 'stdout';
        local *STDOUT = $stdout;
        is( $command->run('--help'), 0, 'help exits 0' );
        close $stdout or croak 'close stdout';
    }
    like( $usage, qr/gpforum-staging-host-verify/msx, 'help names command' );
    like( $usage, qr/private-beta/msx, 'help denies private-beta claim' );
    like( $usage, qr/TLS|https/msx, 'help mentions TLS observe' );
    like( $usage, qr/--unit-dir/msx, 'help mentions unit-dir observe' );
    like( $usage, qr/--nginx-conf/msx, 'help mentions nginx-conf observe' );

    return;
}

sub _test_command_unknown {
    my $command = GPForum::Command::StagingHostVerify->new;
    my $stderr  = q{};
    {
        open my $err, '>', \$stderr or croak 'stderr';
        local *STDERR = $err;
        is( $command->run('--nope'), 2, 'unknown option exits usage' );
        close $err or croak 'close stderr';
    }

    return;
}

sub _test_command_json {
    my $command = GPForum::Command::StagingHostVerify->new;
    my $json    = q{};
    {
        open my $stdout, '>', \$json or croak 'stdout';
        local *STDOUT = $stdout;
        is( $command->run('--json'), 0, 'json verify exits 0' );
        close $stdout or croak 'close stdout';
    }
    my $evidence = decode_json($json);
    is( $evidence->{check}, 'staging_host_verify', 'json check name' );

    return;
}

1;
