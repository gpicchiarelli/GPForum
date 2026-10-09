# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Service::Operations::CacheFactory;
use GPForum::Service::Operations::Profile;
use GPForum::Service::Operations::Readiness;
use GPForum::Test::ReadinessRuntime;
use GPForum::Test::ReadinessSchema;

our $VERSION = '0.001';

# Production required GPFORUM_GLIFISTORE_URL, and no GlifiStore can be
# installed (DEPLOYMENT.md): an operator set any URL to get past the check and
# the node ran degraded for good (walkthrough, item 2). GlifiStore is
# optional everywhere now (owner decision D2): without one each process keeps
# its own cache, which a single host needs no more than.

const my $SECRET => 'p' x 40;
const my %PRODUCTION => (
    environment     => 'production',
    public_base_url => 'https://forum.example.test',
    mail_from       => 'forum@forum.example.test',
    metrics_token   => 'metrics-token',
    session_secret  => $SECRET,
);

for my $environment (qw(development test staging production)) {
    is(
        GPForum::Config->from_environment(
            {
                GPFORUM_ENV             => $environment,
                GPFORUM_PUBLIC_BASE_URL => 'https://forum.example.test',
                GPFORUM_MAIL_FROM       => 'forum@forum.example.test',
                GPFORUM_METRICS_TOKEN   => 'metrics-token',
                GPFORUM_SESSION_SECRET  => $SECRET,
            }
        )->glifistore_url,
        q{},
        "$environment has no GlifiStore unless one is set"
    );
}

my $production = GPForum::Config->new(%PRODUCTION);
lives_ok { $production->validate } 'production validates without one';
ok( !$production->requires_glifistore, 'and does not require one' );
isa_ok(
    GPForum::Service::Operations::CacheFactory->build($production),
    'GPForum::Service::Operations::LocalCache',
    'its cache'
);
ok( GPForum::Service::Operations::Profile->new->evaluate($production)->{ok},
    'its operational profile is met' );

my $report = GPForum::Service::Operations::Readiness->new(
    config         => $production,
    environment    => 'production',
    glifistore_url => q{},
    runtime        => GPForum::Test::ReadinessRuntime->new,
    schema         => GPForum::Test::ReadinessSchema->new,
)->check;
my ($shared) = grep { $_->{name} eq 'shared_cache' } @{ $report->{checks} };
is( $shared->{status}, 'ok', 'readiness finds the shared cache check ok' );
is( $shared->{mode},   'disabled', 'reporting it disabled' );
is(
    $shared->{note},
    'No GlifiStore is configured: each process keeps its own cache. That'
      . ' suits a single host; set GPFORUM_GLIFISTORE_URL to share one between'
      . ' hosts.',
    'with a note an operator can act on'
);
ok( !exists $shared->{runbook}, 'and no runbook, as nothing needs doing' );

lives_ok {
    GPForum::Config->new( %PRODUCTION, glifistore_url => 'tcp://cache:7379' )
      ->validate
}
'one can still be configured';

done_testing();

1;
