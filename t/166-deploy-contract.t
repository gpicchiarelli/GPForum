# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::Service::Operations::DeployContract qw(
  deploy_host_unit_checks
  deploy_match_text
  deploy_nginx_checks
  deploy_unit_checks
);

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 23;

plan tests => $EXPECTED_TESTS;

ok( scalar( deploy_unit_checks() ) >= 4,  'unit contracts cover core units' );
ok( scalar( deploy_nginx_checks() ) >= 2, 'nginx contracts cover tcp+unix' );
is( scalar( deploy_host_unit_checks() ),
    3, 'host unit observe covers web+outbox+scheduled-jobs' );

my @host_names = map { $_->{name} } deploy_host_unit_checks();
ok(
    ( grep { $_ eq 'gpforum-scheduled-jobs.service' } @host_names ),
    'host observe includes scheduled-jobs service contract'
);

my $web = path('deploy/systemd/gpforum.service')->slurp;
my $web_match =
  deploy_match_text( $web, ( deploy_host_unit_checks() )[0] );
is( $web_match->{status}, 'pass', 'repo gpforum.service matches contract' );

my $nginx = path('deploy/nginx/gpforum.conf')->slurp;
my $nginx_match =
  deploy_match_text( $nginx, ( deploy_nginx_checks() )[0] );
is( $nginx_match->{status}, 'pass', 'repo gpforum.conf matches contract' );

my $bad = deploy_match_text( "User=root\n", ( deploy_host_unit_checks() )[0] );
is( $bad->{status}, 'fail', 'broken unit text fails contract' );
ok( @{ $bad->{missing_labels} } >= 1, 'broken unit reports missing labels' );

unlike(
    path('lib/GPForum/Service/Operations/DeployChecklistDrill.pm')->slurp,
    qr/const my \@UNIT_CHECKS/msx,
    'deploy checklist no longer owns UNIT_CHECKS'
);
unlike(
    path('lib/GPForum/Service/Operations/StagingHostVerify.pm')->slurp,
    qr/const my \@UNIT_FILE_CONTRACTS/msx,
    'staging-host verify no longer owns UNIT_FILE_CONTRACTS'
);
like(
    path('lib/GPForum/Service/Operations/StagingHostVerify.pm')->slurp,
    qr/deploy_nginx_checks|nginx_conf/msx,
    'staging-host verify uses shared nginx contracts'
);

# ExecReload was byte-identical to ExecStart, and running hypnotoad against a
# live instance is its hot-deploy path: the new manager sends QUIT to the old
# one, so systemd -- which reads PIDFile once at start -- was left tracking a
# dead process and the reload killed the service. `kill -USR2` is that same hot
# deploy, so there is nothing correct to put in ExecReload at all.
for my $unit (qw(gpforum.service gpforum-unix-socket.service)) {
    my $text = path("deploy/systemd/$unit")->slurp;
    like( $text, qr/^Type=forking$/msx, "$unit still forks" );
    unlike( $text, qr/^ExecReload=/msx,
        "$unit declares no ExecReload, so reload cannot kill it" );
}

# ADR 0050 requires operators to run WAL archiving and PITR. The repository
# used to state that and ship nothing to meet it; these keep the drill and the
# runbook from drifting apart from the requirement.
ok( -x 'script/pitr-drill', 'the point-in-time recovery drill is executable' );
my $drill = path('script/pitr-drill')->slurp;
for my $setting (
    qw(wal_level archive_mode archive_command restore_command
    recovery_target_time)
  )
{
    like( $drill, qr/\Q$setting\E/msx, "the drill exercises $setting" );
}

my $runbook = path('docs/ops/backup-and-restore.md')->slurp;
like( $runbook, qr/recovery_target_time/msx,
    'the runbook names the recovery target setting' );
like(
    $runbook,
    qr/attachment \s root/msx,
    'the runbook says attachments are outside the database backup'
);

1;
