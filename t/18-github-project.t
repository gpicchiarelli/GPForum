package main;

use strict;
use warnings;

use Const::Fast;
use Mojo::File qw(path);
use Test::More;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 144;
const my $CURLY_CLASS    => '[{]';

plan tests => $EXPECTED_TESTS;

for my $required_file (
    qw(
    .github/workflows/ci.yml
    .github/workflows/project-hygiene.yml
    .github/dependabot.yml
    .github/CODEOWNERS
    .github/pull_request_template.md
    .github/ISSUE_TEMPLATE/config.yml
    .github/ISSUE_TEMPLATE/bug_report.yml
    .github/ISSUE_TEMPLATE/feature_request.yml
    .github/ISSUE_TEMPLATE/architecture_decision.yml
    CONTRIBUTING.md
    SECURITY.md
    CODE_OF_CONDUCT.md
    SUPPORT.md
    GOVERNANCE.md
    ROADMAP.md
    CHANGELOG.md
    docs/adr/README.md
    docs/adr/0000-template.md
    docs/BASELINE.md
    docs/CPAN_LICENSE_REVIEW.md
    docs/OPERATIONAL_BASELINE.md
    docs/PERFORMANCE_BASELINE.md
    docs/PERFORMANCE_EVIDENCE.md
    docs/SECURITY_HARDENING.md
    docs/OS_OPTIMIZATION.md
    docs/OS_RUNTIME_ENFORCEMENT.md
    docs/OS_RUNTIME_EVIDENCE.md
    docs/DEPLOYMENT.md
    docs/DEPLOYMENT_EVIDENCE.md
    docs/ops/scheduled-jobs.md
    docs/ops/staging-drills.md
    docs/ops/staging-host.md
    docs/ops/stress-load.md
    docs/ops/mail-check.md
    docs/ops/private-beta-checklist.md
    docs/PRODUCTION_READINESS.md
    deploy/systemd/gpforum.service
    deploy/systemd/gpforum-outbox.service
    deploy/systemd/gpforum-scheduled-jobs.service
    deploy/systemd/gpforum-scheduled-jobs.timer
    deploy/systemd/gpforum-unix-socket.service
    deploy/freebsd/gpforum
    deploy/launchd/com.gpforum.app.plist
    deploy/launchd/com.gpforum.scheduled-jobs.plist
    deploy/nginx/gpforum.conf
    deploy/nginx/gpforum-unix-socket.conf
    deploy/caddy/Caddyfile
    prompt/44.txt
    bin/gpforum-benchmark
    bin/gpforum-bench-hypnotoad
    bin/gpforum-bench-hypnotoad-scaling
    bin/gpforum-os-preflight
    bin/gpforum-scheduled-jobs
    bin/gpforum-query-plan-evidence
    bin/gpforum-seed-benchmark
    bin/gpforum-seed-performance-data
    bin/gpforum-staging-drill
    bin/gpforum-staging-drill-attachments
    bin/gpforum-staging-host-verify
    bin/gpforum-stress-load
    script/bench-http
    script/bench-hotpaths
    script/bench-hypnotoad
    script/bench-hypnotoad-scaling
    script/benchmark-http
    script/cpan-license-check
    script/gpforum-carton
    script/gpforum-macports-env
    script/gpforum-system-perl
    script/perl-syntax-check
    script/perltidy-check
    script/gpforum-os-preflight
    script/profile-nytprof
    script/query-budget
    script/query-plan-evidence
    script/seed-benchmark
    script/seed-performance-data
    script/staging-drill
    script/staging-drill-attachments
    script/staging-host-verify
    script/stress-load
    script/gpforum-private-beta-checklist
    )
  )
{
    ok( -f $required_file, "$required_file exists" );
}

my $ci             = path('.github/workflows/ci.yml')->slurp;
my $pull           = path('.github/pull_request_template.md')->slurp;
my $prompt         = path('prompt/44.txt')->slurp;
my $readme         = path('README.md')->slurp;
my $governance     = path('GOVERNANCE.md')->slurp;
my $deployment     = path('docs/DEPLOYMENT.md')->slurp;
my $readiness      = path('docs/PRODUCTION_READINESS.md')->slurp;
my $systemd_web    = path('deploy/systemd/gpforum.service')->slurp;
my $systemd_outbox = path('deploy/systemd/gpforum-outbox.service')->slurp;
my $systemd_jobs = path('deploy/systemd/gpforum-scheduled-jobs.service')->slurp;
my $systemd_jobs_timer =
  path('deploy/systemd/gpforum-scheduled-jobs.timer')->slurp;
my $systemd_socket = path('deploy/systemd/gpforum-unix-socket.service')->slurp;
my $launchd_jobs =
  path('deploy/launchd/com.gpforum.scheduled-jobs.plist')->slurp;
my $freebsd_rc    = path('deploy/freebsd/gpforum')->slurp;
my $launchd_plist = path('deploy/launchd/com.gpforum.app.plist')->slurp;
my $nginx         = path('deploy/nginx/gpforum.conf')->slurp;
my $nginx_unix    = path('deploy/nginx/gpforum-unix-socket.conf')->slurp;
my $caddy         = path('deploy/caddy/Caddyfile')->slurp;

like(
    $ci,
    qr/script\/gpforum-system-perl [ ] --preflight/msx,
    'CI verifies OS system Perl before installing Carton deps'
);
like(
    $ci,
    qr/readlink [ ]+-f.*\/usr\/bin\/perl|test .*\/usr\/bin\/perl/msx,
    'CI asserts PATH perl is /usr/bin/perl'
);
like(
    $ci,
    qr/run: [ ] script\/perlcritic/msx,
    'CI runs Perl::Critic through the repository baseline gate'
);
like(
    $ci,
    qr/script\/gpforum-carton [ ] exec [ ] script\/perl-syntax-check/msx,
    'CI runs Perl syntax check through system-Perl Carton'
);
like(
    $ci,
    qr/script\/bootstrap-deps [ ] --postgres/msx,
    'CI installs optional PostgreSQL dependencies for DB gates'
);
like(
    $ci,
    qr/script\/gpforum-carton [ ] exec [ ] prove [ ] -lr [ ] t/msx,
    'CI runs prove -lr t through system-Perl Carton'
);
like( $ci, qr/script\/coverage/msx,    'CI runs coverage' );
like( $ci, qr/gpforum-benchmark/msx,   'CI runs benchmark smoke' );
like( $ci, qr/script\/bench-hypnotoad/msx,
    'CI runs Hypnotoad benchmark smoke' );
like( $ci, qr/script\/perltidy-check/msx, 'CI checks Perl formatting' );
like(
    $ci,
    qr/script\/architecture-check/msx,
    'CI runs architecture boundary check'
);
like(
    $ci,
    qr/script\/cpan-license-check/msx,
    'CI runs dependency license review check'
);
like(
    $ci,
    qr/gpforum-migrate [ ] --apply/msx,
    'CI applies migrations against PostgreSQL'
);
like(
    $ci,
    qr/script\/query-budget [ ] --check/msx,
    'CI checks query budget through script wrapper'
);
like(
    $ci,
    qr/script\/query-plan-evidence [ ] --check/msx,
    'CI checks DB-backed query plan evidence'
);
like(
    $ci,
    qr/script\/gpforum-os-preflight [ ] --json/msx,
    'CI runs OS preflight'
);
like(
    $ci,
    qr/gpforum-platform-check [ ] --with-db/msx,
    'CI runs database-backed platform check'
);
like(
    $ci,
    qr/actions\/upload-artifact\@[[:xdigit:]]{40} [ ] \# [ ] v7/msx,
    'CI uploads coverage artifacts from a SHA-pinned action'
);
like(
    $pull,
    qr/Architecture [ ] Alignment/msx,
    'pull request template asks for architecture alignment'
);
like( $pull, qr/script\/coverage/msx,
    'pull request template asks for coverage evidence' );
like(
    $prompt,
    qr/GitHub [ ] Project [ ] Success [ ] Contract/msx,
    'prompt 44 defines GitHub project success'
);
like(
    $readme,
    qr/GitHub [ ] project [ ] success [ ] surface/msx,
    'README points to the GitHub project success surface'
);
like( $readme, qr/script\/bench-http/msx,
    'README documents the HTTP benchmark command' );
like(
    $governance,
    qr/Giacomo [ ] Picchiarelli/msx,
    'governance keeps the correct maintainer identity'
);
like(
    $systemd_web,
    qr/EnvironmentFile=\/etc\/gpforum\/gpforum[.]env/msx,
    'systemd web unit loads production environment file'
);
like(
    $systemd_outbox,
    qr/EnvironmentFile=\/etc\/gpforum\/gpforum[.]env/msx,
    'systemd outbox unit loads production environment file'
);
like(
    $systemd_socket,
    qr/EnvironmentFile=\/etc\/gpforum\/gpforum[.]env/msx,
    'systemd unix socket unit loads production environment file'
);
like(
    $deployment,
    qr/\/etc\/gpforum\/gpforum[.]env/msx,
    'deployment docs name the systemd environment file'
);
like(
    $readiness,
    qr/\/etc\/gpforum\/gpforum[.]env/msx,
    'production readiness docs name the systemd environment file'
);
like(
    $deployment,
    qr/script\/query-budget [ ] --sync/msx,
    'deployment docs require query budget sync before readiness'
);
like(
    $readiness,
    qr/script\/query-budget [ ] --sync/msx,
    'production readiness docs require query budget sync'
);
like(
    $systemd_web,
    qr{script/gpforum-carton [ ] exec [ ] hypnotoad}msx,
    'systemd web unit starts Hypnotoad through script/gpforum-carton'
);
unlike(
    $systemd_web,
    qr{/opt/gpforum/local/bin/carton}msx,
    'systemd web unit does not call local/bin/carton'
);
like(
    $systemd_outbox,
    qr{script/gpforum-carton [ ] exec}msx,
    'systemd outbox unit starts through script/gpforum-carton'
);
unlike(
    $systemd_outbox,
    qr{/opt/gpforum/local/bin/carton}msx,
    'systemd outbox unit does not call local/bin/carton'
);
like(
    $systemd_socket,
    qr{script/gpforum-carton [ ] exec [ ] hypnotoad}msx,
    'systemd unix socket unit starts Hypnotoad through script/gpforum-carton'
);
unlike(
    $systemd_socket,
    qr{/opt/gpforum/local/bin/carton}msx,
    'systemd unix socket unit does not call local/bin/carton'
);
like(
    $systemd_web,
    qr/RuntimeDirectory=gpforum/msx,
    'systemd web unit creates /run/gpforum'
);
like(
    $systemd_socket,
    qr/RuntimeDirectory=gpforum/msx,
    'systemd unix socket unit creates /run/gpforum'
);
like(
    $freebsd_rc,
    qr{script/gpforum-carton [ ] exec [ ] hypnotoad}msx,
    'FreeBSD rc starts Hypnotoad through script/gpforum-carton'
);
like( $launchd_plist, qr{script/gpforum-carton}msx,
    'launchd starts through script/gpforum-carton' );
unlike( $nginx, qr{public/assets}msx,
    'nginx does not serve a missing public/assets path' );
like(
    $nginx,
    qr{root [ ] /opt/gpforum;}msx,
    'nginx serves /assets/ from the repo assets tree'
);
unlike(
    $nginx,
    qr{location [ ] /attachments/ [ ] $CURLY_CLASS \s* internal;}msx,
    'nginx does not mark /attachments/ internal'
);
like(
    $nginx,
    qr{location [ ] /internal-attachments/}msx,
    'nginx keeps an internal alias for X-Accel-Redirect'
);
like(
    $nginx_unix,
    qr{root [ ] /opt/gpforum;}msx,
    'unix-socket nginx serves /assets/ from the repo assets tree'
);
unlike( $caddy, qr{public/assets}msx,
    'Caddy does not serve a missing public/assets path' );
like(
    $caddy,
    qr{root [ ] [*] [ ] /opt/gpforum}msx,
    'Caddy serves /assets/ from the repo assets tree'
);
like( $deployment, qr/GlifiStore::Client/msx,
    'deployment docs name the operator-supplied GlifiStore client' );
like( $systemd_jobs, qr/Type=oneshot/msx,
    'scheduled jobs systemd unit is oneshot, not a daemon' );
like(
    $systemd_jobs,
    qr{script/gpforum-carton [ ] exec}msx,
    'scheduled jobs systemd unit starts through script/gpforum-carton'
);
unlike(
    $systemd_jobs,
    qr{/opt/gpforum/local/bin/carton}msx,
    'scheduled jobs systemd unit does not call local/bin/carton'
);
like(
    $systemd_jobs,
    qr/EnvironmentFile=\/etc\/gpforum\/gpforum[.]env/msx,
    'scheduled jobs systemd unit loads production environment file'
);
like( $systemd_jobs_timer, qr/OnCalendar=hourly/msx,
    'scheduled jobs timer runs hourly' );
like( $launchd_jobs, qr{script/gpforum-carton}msx,
    'scheduled jobs launchd starts through script/gpforum-carton' );
like( $launchd_jobs, qr/StartInterval/msx,
    'scheduled jobs launchd repeats on an interval' );
like( $deployment, qr/gpforum-scheduled-jobs/msx,
    'deployment docs name the scheduled jobs timer' );
    like(
        path('docs/ops/staging-drills.md')->slurp,
        qr/script\/staging-drill-attachments/msx,
        'staging drills docs cover attachment/deploy rehearsal entrypoint'
    );
    like(
        path('docs/ops/staging-drills.md')->slurp,
        qr/gpforum-macports-env/msx,
        'staging drills docs cover MacPorts PATH helper'
    );
    like(
        path('docs/ops/staging-host.md')->slurp,
        qr/script\/staging-host-verify/msx,
        'staging host docs cover verify entrypoint'
    );
    like(
        path('docs/ops/private-beta-checklist.md')->slurp,
        qr/gpforum-private-beta-checklist|PRIVATE BETA/msx,
        'private-beta checklist aggregates operator prep tools'
    );
    like(
        path('script/gpforum-private-beta-checklist')->slurp,
        qr/not-claimed|NOT CLAIMED/msx,
        'private-beta checklist script does not claim readiness'
    );

1;
