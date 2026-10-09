# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use Cwd        qw(getcwd);
use English    qw(-no_match_vars);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Test::More;

use lib 'lib';

our $VERSION = '0.001';

const my $EXIT_FAILURE => 1;
const my $STATUS_SHIFT => 8;

# A gate that checked nothing has not passed. Each of these used to report
# success in exactly that situation: perlcritic when the analyser was not on
# PATH, perl-syntax-check and the coverage gate when they found no files,
# query-plan-check when CI lost its database DSN or when a required index had
# been dropped by a later migration. The first was found in practice -- it had
# passed without running for as long as this host existed.
my $root = getcwd();

# perl-syntax-check, pointed at a directory with no Perl in it.
{
    my $empty = tempdir( CLEANUP => 1 );
    chdir $empty or croak "chdir $empty: $ERRNO";
    my ( $status, $output ) =
      _run( $EXECUTABLE_NAME, "$root/script/perl-syntax-check" );
    chdir $root or croak "chdir $root: $ERRNO";

    is( $status, $EXIT_FAILURE,
        'perl-syntax-check fails when it finds nothing to check' );
    like(
        $output,
        qr/nothing \s was \s checked/msx,
        'and says that nothing was checked'
    );
}

# query-plan-check, required to reach the database and given no DSN.
{
    local $ENV{GPFORUM_DATABASE_DSN} = undef;
    delete $ENV{GPFORUM_DATABASE_DSN};

    my ( $status, $output ) = _run( $EXECUTABLE_NAME, '-Ilib',
        'script/query-plan-check', '--require-db' );
    is( $status, $EXIT_FAILURE,
        'query-plan-check --require-db fails without a DSN' );
    like(
        $output,
        qr/db_evidence=missing-dsn/msx,
        'and names the missing DSN rather than reporting a skip'
    );

    my ( undef, $lenient ) =
      _run( $EXECUTABLE_NAME, '-Ilib', 'script/query-plan-check' );
    like( $lenient, qr/db_evidence=skipped/msx,
        'without the flag a laptop run still skips, visibly' );
    like( $lenient, qr/status=ok/msx,
        'and every index it requires exists after all migrations' );
}

# The gates that CI runs must not be configured to be unable to fail.
{
    unlike(
        _slurp('Makefile'),
        qr/script\/perlcritic \s+ --severity/msx,
        'make critic does not override the profile severity'
    );

    my $ci = _slurp('.github/workflows/ci.yml');
    like(
        $ci,
        qr/query-plan-check \s+ --require-db/msx,
        'CI requires the database half of the query-plan gate'
    );
    like( $ci, qr/script\/coverage \b/msx, 'CI runs the coverage gate' );

    # Commands only: the script's comments quote the old pattern on purpose.
    my $coverage = join "\n",
      grep { !/\A \s* [#]/msx } split /\n/msx, _slurp('script/coverage');
    like( $coverage, qr/coverage-check/msx,
        'the coverage gate delegates to a verdict that can fail' );
    like(
        $coverage,
        qr/-select_re \s+ '\^lib\/'/msx,
        'the coverage report selects lib/ only'
    );
    unlike(
        $coverage,
        qr/[(] lib\/GPForum [|] t [)]/msx,
        'the coverage report no longer counts the tests themselves'
    );
}

# The PostgreSQL integration tier: without a DSN every test in it skips, so
# the make target must refuse rather than report an empty success, and no
# workflow may run it as a list of files, which is how the search-plan and
# retention tests went unrun on PostgreSQL 17 and 18.
{
    local $ENV{GPFORUM_DATABASE_DSN} = undef;
    delete $ENV{GPFORUM_DATABASE_DSN};

    my ( $status, $output ) = _run( 'make', '-s', 'integration' );
    isnt( $status, 0, 'make integration fails without a DSN' );
    like(
        $output,
        qr/nothing \s was \s tested/msx,
        'and says that nothing was tested'
    );

    for my $workflow (qw(ci postgres-matrix)) {
        my $text = _slurp(".github/workflows/$workflow.yml");
        like(
            $text,
            qr/make \s+ integration/msx,
            "$workflow.yml runs the whole integration tier"
        );
        unlike(
            $text,
            qr{t/integration/[\w-]+[.]t}msx,
            "$workflow.yml names no single integration file"
        );
    }
}

# The ADR index is generated; a new ADR that is not indexed fails here rather
# than joining the 103 that nobody could find by browsing.
{
    my ( $status, $output ) =
      _run( $EXECUTABLE_NAME, '-Ilib', 'script/adr-index', '--check' );
    is( $status, 0, 'the ADR index in docs/adr/README.md is current' )
      or diag $output;
}

# Execute the workflow's own action pinning gate: whitespace used to make
# its matcher backtrack and reject every local composite action in CI.
_check_action_pinning_gate($root);

done_testing();

sub _check_action_pinning_gate {
    my ($project_root) = @_;
    my $step   = quotemeta 'Assert every action is pinned to a commit SHA';
    my ($gate) = _slurp('.github/workflows/security.yml') =~
      m{$step \n [ ]{8} run: [ ] [|] \n (.*?) \n\n}msx;
    defined $gate or croak 'security workflow has no action pinning gate';
    $gate =~ s/^[ ]{10}//gmsx;

    my $sha = '3d3c42e5aac5ba805825da76410c181273ba90b1';
    for my $case (
        [ 'local action', '        uses: ./.github/actions/setup-perl', 0 ],
        [ 'local action with extra spaces', '  uses:     ./setup-perl', 0 ],
        [ 'quoted local action',            q{  uses: './setup-perl'},  0 ],
        [ 'double-quoted local action',     q{  uses: "./setup-perl"},  0 ],
        [ 'local list entry',               '  - uses: ./setup-perl',   0 ],
        [ 'pinned action', "  uses: actions/checkout\@$sha # v7.0.1",   0 ],
        [
            'quoted pinned action',
            "  uses: 'actions/checkout\@$sha' # v7.0.1", 0
        ],
        [ 'pinned list entry', "  - uses: actions/checkout\@$sha # v7.0.1", 0 ],
        [ 'mutable action tag', '  uses: actions/checkout@v7 # v7.0.1',     1 ],
        [ 'mutable list entry', '  - uses: actions/checkout@main',          1 ],
        [ 'quoted mutable tag', q{  uses: "actions/checkout@v7"},           1 ],
        [ 'missing version comment', "  uses: actions/checkout\@$sha",      1 ],
        [ 'empty version comment',   "  uses: actions/checkout\@$sha #",    1 ],
        [
            'SHA longer than forty digits',
            "  uses: actions/checkout\@${sha}0 # v7",
            1
        ],
        [ 'tab-separated mutable tag', "\tuses:\tactions/checkout\@v7", 1 ],
      )
    {
        my ( $name, $uses, $expected ) = @{$case};
        my $fixture = tempdir( CLEANUP => 1 );
        make_path( "$fixture/.github/workflows", "$fixture/.github/actions" );
        my $path = "$fixture/.github/workflows/example.yml";
        open my $handle, '>', $path or croak "open $path: $ERRNO";
        print {$handle} "$uses\n" or croak "write $path: $ERRNO";
        close $handle             or croak "close $path: $ERRNO";

        chdir $fixture or croak "chdir $fixture: $ERRNO";
        my ( $status, $output ) = _run( 'bash', '-c', $gate );
        chdir $project_root or croak "chdir $project_root: $ERRNO";
        is( $status, $expected, "action pinning gate: $name" ) or diag $output;
    }
    return;
}

# Runs a command without a shell and returns its exit status and its combined
# output. With no separate error handle, open3 puts the child's stderr on the
# same handle as its stdout.
sub _run {
    my (@command) = @_;

    my $pid = open3( my $input, my $output, undef, @command );
    close $input or croak "close child input: $ERRNO";
    my $text = do {
        local $INPUT_RECORD_SEPARATOR = undef;
        <$output>;
    };
    waitpid $pid, 0;

    return ( $CHILD_ERROR >> $STATUS_SHIFT, $text // q{} );
}

sub _slurp {
    my ($path) = @_;

    open my $handle, '<', $path or croak "open $path: $ERRNO";
    local $INPUT_RECORD_SEPARATOR = undef;
    my $text = <$handle>;
    close $handle or croak "close $path: $ERRNO";

    return $text;
}

1;
