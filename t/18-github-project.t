package main;

use strict;
use warnings;

use Const::Fast;
use Mojo::File qw(path);
use Test::More;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 27;

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
    prompt/44.txt
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

like( $ci, qr/script\/perlcritic/msx, 'CI runs Perl::Critic' );
like( $ci, qr/script\/test/msx,       'CI runs tests' );
like( $ci, qr/script\/coverage/msx,   'CI runs coverage' );
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
like(
    $governance,
    qr/Giacomo [ ] Picchiarelli/msx,
    'governance keeps the correct maintainer identity'
);

1;
