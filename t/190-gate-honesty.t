# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Cwd        qw(getcwd);
use English    qw(-no_match_vars);
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

done_testing();

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
