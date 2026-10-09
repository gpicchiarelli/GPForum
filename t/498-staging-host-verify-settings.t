# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use File::Temp    qw(tempdir);
use JSON::MaybeXS qw(encode_json);
use Mojo::File    qw(path);
use Test::More;

use lib 'lib';

use GPForum::Service::Operations::StagingHostVerify;

our $VERSION = '0.001';

# The walkthrough's friction 16: staging-host-verify passed an environment
# file holding its four keys, and the service then refused to start on what
# the file left out or got wrong. It now checks every setting as the
# service does at its start -- the checks gpforum doctor reports -- and
# still never copies a value into the evidence.

const my $SECRET => 'f00dfeedf00dfeedf00dfeedf00dfeedf00dfeed';
my $directory = tempdir( CLEANUP => 1 );

subtest 'four keys set are not a file the service starts with' => sub {
    my $evidence = _verify(<<"ENV");
GPFORUM_SESSION_SECRET=short
GPFORUM_DATABASE_DSN=dbi:Pg:dbname=gpforum
GPFORUM_DATABASE_USER=gpforum
GPFORUM_METRICS_TOKEN=$SECRET
ENV
    is_deeply( $evidence->{missing_keys}, [], 'the four keys are there' );
    is( $evidence->{status},      'fail',       'but the phase fails' );
    is( $evidence->{environment}, 'production', 'checked as the units run it' );
    my %problem = map { $_->{variable} => $_ } @{ $evidence->{problems} };
    ok(
        exists $problem{GPFORUM_PUBLIC_BASE_URL},
        'the address left on its development default'
    );
    ok( exists $problem{GPFORUM_SESSION_SECRET}, 'the short secret' );
    like(
        $problem{GPFORUM_SESSION_SECRET}{sentence},
        qr/GPFORUM_SESSION_SECRET [ ] is [ ] 5 [ ] characters/msx,
        'each with the sentence the service would say'
    );
    unlike( encode_json($evidence), qr/\Q$SECRET\E|=short\b/msx,
        'and no value reaches the evidence' );
};

subtest 'a file the service starts with passes' => sub {
    my $evidence = _verify(<<"ENV");
GPFORUM_SESSION_SECRET=$SECRET
GPFORUM_DATABASE_DSN=dbi:Pg:dbname=gpforum
GPFORUM_DATABASE_USER=gpforum
GPFORUM_METRICS_TOKEN=$SECRET
GPFORUM_PUBLIC_BASE_URL=https://staging.gpforum.net
GPFORUM_MAIL_FROM=forum\@staging.gpforum.net
ENV
    is( $evidence->{status}, 'pass', 'pass' );
    is_deeply( $evidence->{problems}, [], 'no problem' );
};

subtest q{the file's own GPFORUM_ENV, and its last assignment, decide} => sub {
    my $evidence = _verify(<<"ENV");
GPFORUM_ENV=staging
GPFORUM_SESSION_SECRET=$SECRET
GPFORUM_DATABASE_DSN=dbi:Pg:dbname=gpforum
GPFORUM_DATABASE_USER=gpforum
GPFORUM_METRICS_TOKEN=$SECRET
GPFORUM_PUBLIC_BASE_URL=http://wrong
GPFORUM_PUBLIC_BASE_URL=https://staging.gpforum.net
GPFORUM_MAIL_FROM=forum\@staging.gpforum.net
ENV
    is( $evidence->{environment}, 'staging', 'staging, as the file says' );
    is( $evidence->{status},      'pass',    'and the later address counts' );
};

subtest 'the human form lists the problems under the phase' => sub {
    my $path = path( $directory, 'human.env' );
    $path->spew("GPFORUM_ENV=prod\n");
    my $verify = GPForum::Service::Operations::StagingHostVerify->new;
    my $text   = $verify->format_evidence(
        $verify->run( { env_file => $path->to_string } ), 'human' );
    like(
        $text,
        qr/^env_file [ ] status=fail\n [ ][ ]GPFORUM_ENV [ ] must [ ] be/msx,
        'each problem indented under env_file'
    );
};

done_testing();

sub _verify ($text) {
    my $path = path( $directory, 'gpforum.env' );
    $path->spew($text);

    return GPForum::Service::Operations::StagingHostVerify->new->run(
        { env_file => $path->to_string } )->{env_file};
}

1;
