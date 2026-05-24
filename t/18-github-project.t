package main;

use strict;
use warnings;

use Const::Fast;
use Mojo::File qw(path);
use Test::More;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 76;

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
    deploy/systemd/gpforum.service
    deploy/systemd/gpforum-unix-socket.service
    deploy/freebsd/gpforum
    deploy/launchd/com.gpforum.app.plist
    deploy/nginx/gpforum.conf
    deploy/nginx/gpforum-unix-socket.conf
    deploy/caddy/Caddyfile
    prompt/44.txt
    bin/gpforum-benchmark
    bin/gpforum-bench-hypnotoad
    bin/gpforum-os-preflight
    bin/gpforum-query-plan-evidence
    bin/gpforum-seed-benchmark
    bin/gpforum-seed-performance-data
    script/bench-http
    script/bench-hotpaths
    script/bench-hypnotoad
    script/benchmark-http
    script/cpan-license-check
    script/perltidy-check
    script/gpforum-os-preflight
    script/profile-nytprof
    script/query-budget
    script/query-plan-evidence
    script/seed-benchmark
    script/seed-performance-data
    )
  )
{
    ok( -f $required_file, "$required_file exists" );
}

my $ci         = path('.github/workflows/ci.yml')->slurp;
my $pull       = path('.github/pull_request_template.md')->slurp;
my $prompt     = path('prompt/44.txt')->slurp;
my $readme     = path('README.md')->slurp;
my $governance = path('GOVERNANCE.md')->slurp;

like(
    $ci,
    qr/script\/perlcritic [ ] --severity [ ] 5/msx,
    'CI runs Perl::Critic at severity 5'
);
like(
    $ci,
    qr/script\/bootstrap-deps [ ] --postgres/msx,
    'CI installs optional PostgreSQL dependencies for DB gates'
);
like( $ci, qr/prove [ ] -lr [ ] t/msx, 'CI runs prove -lr t' );
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
    qr/actions\/upload-artifact\@v4/msx,
    'CI uploads coverage artifacts'
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

1;
