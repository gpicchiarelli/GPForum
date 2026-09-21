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

const my $EXPECTED_TESTS => 11;

plan tests => $EXPECTED_TESTS;

ok( scalar( deploy_unit_checks() ) >= 4, 'unit contracts cover core units' );
ok( scalar( deploy_nginx_checks() ) >= 2, 'nginx contracts cover tcp+unix' );
is( scalar( deploy_host_unit_checks() ),
    3, 'host unit observe covers web+outbox+scheduled-jobs' );

my @host_names = map { $_->{name} } deploy_host_unit_checks();
ok( ( grep { $_ eq 'gpforum-scheduled-jobs.service' } @host_names ),
    'host observe includes scheduled-jobs service contract' );

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

1;
