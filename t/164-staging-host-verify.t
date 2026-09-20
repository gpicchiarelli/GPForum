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

const my $EXPECTED_TESTS => 19;

plan tests => $EXPECTED_TESTS;

_test_prerequisites_only();
_test_env_file_keys();
_test_metrics_header();
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
    is( $evidence->{health}{status},   'skipped', 'health skipped by default' );
    ok( @{ $evidence->{residual_gaps} } >= 1,
        'residual gaps note live staging evidence' );

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
