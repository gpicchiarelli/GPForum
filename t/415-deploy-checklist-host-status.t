# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::Service::Operations::DeployChecklistDrill;
use GPForum::Service::Operations::DeployContract
  qw(deploy_nginx_checks deploy_unit_checks);

our $VERSION = '0.001';

# The deploy checklist checks the templates' text, then renders each one into
# a throwaway workspace and has systemd-analyze verify and nginx -t read it.
# Fake tools on PATH stand in for both: they keep what they were given and
# answer as told. A static failure fails the drill; then a host check that
# failed fails it, and one that could not run (no tool on PATH) degrades it.
my $repo = path(q{.})->realpath;
my $log  = path( tempdir( CLEANUP => 1 ) );
my $user = getpwuid $EFFECTIVE_USER_ID;
my $degraded_line =
  'host_validation status=degraded systemd=pass nginx=skipped';

# The probe's own certificate: the fake openssl writes the two files it is
# asked for, and the fake nginx refuses a site that still names a host path, a
# privileged or IPv6 listen address, or a certificate that is not there.
my $openssl =
q{while [ $# -gt 0 ]; do case "$1" in -keyout|-out) : > "$2"; shift;; esac; shift; done; exit 0};
my $nginx_reads_site = <<'SH';
PATH=/usr/bin:/bin
site=$(awk '$1 == "include" { sub(/;$/, "", $2); print $2 }' "$3")
if grep -Ev '^[[:space:]]*#' "$site" | grep -Eq 'letsencrypt|\[::\]|listen 80;|listen 443'; then
  echo "nginx: [emerg] host path in $site" >&2; exit 1
fi
for file in $(awk '$1 ~ /^ssl_certificate/ { sub(/;$/, "", $2); print $2 }' "$site"); do
  [ -f "$file" ] || { echo "nginx: [emerg] cannot load certificate $file" >&2; exit 1; }
done
SH
my $passing = _tools(
    'systemd-analyze' => qq{/bin/cp "\$2" "$log/"\necho checked\necho\nexit 0},
    nginx   => qq{echo "\$*" >> "$log/nginx.args"\n${nginx_reads_site}exit 0},
    openssl => $openssl,
);
my $failing_nginx = _tools(
    'systemd-analyze' => 'exit 0',
    nginx   => qq{echo 'nginx: [emerg] unknown directive' >&2\nexit 1},
    openssl => $openssl,
);
my $no_openssl = _tools(
    'systemd-analyze' => 'exit 0',
    nginx             => 'exit 0',
);
my $systemd_only = _tools( 'systemd-analyze' => 'exit 0' );

my $passed = _drill( $repo, $passing );
is( $passed->{status}, 'pass', 'templates and both host checks pass' );
my $host = $passed->{deploy_checklist}{host_validation};
is( $host->{status}, 'pass', 'so does the host validation' );
my @units = @{ $host->{systemd}{units} };
is( scalar @units, scalar( deploy_unit_checks() ), 'every unit is verified' );
is( $units[0]{output}, 'checked',
    q{a tool's output is kept without its trailing blank lines} );
is( $units[0]{exit}, 0, 'with its exit status' );
like( $log->child( $units[0]{name} )->slurp,
    qr/^User=\Q$user\E$/msx,
    'a unit is verified as the user running the drill' );
is(
    scalar @{ $host->{nginx}{configs} },
    scalar( deploy_nginx_checks() ),
    'every nginx site is tested'
);
like(
    $log->child('nginx.args')->slurp,
    qr/\A -t [ ] -c [ ] \S+ nginx[.]conf [ ] -p [ ] \S+ $/msx,
    'with nginx -t on a main config under its own prefix'
);
is( $passed->{_workspace}, undef, 'and the workspace is removed' );

my $failed = _drill( $repo, $failing_nginx );
my $config = $failed->{deploy_checklist}{host_validation}{nginx}{configs}[0];
is( $config->{status}, 'fail', 'nginx -t that exits 1 fails the site' );
is( $config->{exit},   1,      'reporting the exit status' );
is( $config->{output}, 'nginx: [emerg] unknown directive', 'and the output' );
is( $failed->{deploy_checklist}{host_validation}{status},
    'fail', 'which fails the host validation' );
is( $failed->{status}, 'fail', 'and the drill' );

my $degraded = _drill( $repo, $systemd_only );
my $skipped  = $degraded->{deploy_checklist}{host_validation};
is( $skipped->{nginx}{status}, 'skipped', 'nginx not on PATH is skipped' );
is( $skipped->{status},  'degraded', 'which degrades the host validation' );
is( $degraded->{status}, 'degraded', 'and the drill' );
is(
    GPForum::Service::Operations::DeployChecklistDrill->new->exit_status(
        $degraded),
    0,
    'a degraded drill still exits 0'
);
like(
    GPForum::Service::Operations::DeployChecklistDrill->new->format_evidence(
        $degraded, 'human'
    ),
    qr/^\Q$degraded_line\E$/msx,
    'the human text names each host check'
);

# A template that misses what the contract asks for fails the drill even
# when the host accepts it.
my $broken = path( tempdir( CLEANUP => 1 ) );
for my $check ( deploy_unit_checks(), deploy_nginx_checks() ) {
    my $target = $broken->child( $check->{path} );
    $target->dirname->make_path;
    $repo->child( $check->{path} )->copy_to($target);
}
my ($site) = deploy_nginx_checks();
$broken->child( $site->{path} )->spew("server {}\n");
my $static = _drill( $broken, $passing );
my ($static_site) =
  grep { $_->{name} eq $site->{name} }
  @{ $static->{deploy_checklist}{nginx_configs} };
is( $static_site->{status}, 'fail', 'a bare nginx template fails its check' );
is( $static->{deploy_checklist}{host_validation}{status},
    'pass', 'though nginx -t accepts it' );
is( $static->{status}, 'fail', 'and the drill fails' );

my $without_openssl = _drill( $repo, $no_openssl );
is( $without_openssl->{deploy_checklist}{host_validation}{nginx}{status},
    'skipped', 'nginx -t is skipped when no certificate can be made for it' );
like( $without_openssl->{deploy_checklist}{host_validation}{nginx}{reason},
    qr/openssl/msx, 'and the reason names openssl' );

my $rootless =
  GPForum::Service::Operations::DeployChecklistDrill->new( repo_root => q{} )
  ->run( {} );
is( $rootless->{status}, 'fail', 'a drill with no repository root fails' );
is( $rootless->{error},  'repository root not found', 'saying why' );

done_testing();

sub _drill ( $root, $tools ) {
    local $ENV{PATH} = $tools;

    return GPForum::Service::Operations::DeployChecklistDrill->new(
        repo_root => $root->to_string )->run( {} );
}

sub _tools (%body_of) {
    my $directory = path( tempdir( CLEANUP => 1 ) );
    for my $name ( keys %body_of ) {
        my $tool = $directory->child($name);
        $tool->spew("#!/bin/sh\n$body_of{$name}\n");
        $tool->chmod( oct '0755' );
    }

    return $directory->to_string;
}

1;
