# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use English qw(-no_match_vars);
use Const::Fast;
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Test::More;

our $VERSION = '0.001';

const my $HELPER            => 'script/gpforum-private-beta-checklist';
const my $EXIT_STATUS_SHIFT => 8;
const my $EXPECTED_TESTS    => 10;
const my $AGGREGATED_TOOLS => join q{|}, qw(
  staging-drill staging-host-verify stress-load
  mail-check query-budget rebuild-local
);

plan tests => $EXPECTED_TESTS;

ok( -x $HELPER, 'gpforum-private-beta-checklist is executable' );

my $src = path($HELPER)->slurp;
like(
    $src,
    qr/NOT CLAIMED|not-claimed/msx,
    'helper refuses to claim private-beta readiness'
);
like( $src, qr/$AGGREGATED_TOOLS/msx,
    'helper lists aggregated operator tools' );
unlike(
    $src,
    qr/exec [ ] script\/stress-load|exec [ ] script\/staging-drill/msx,
    'helper does not exec stress-load or staging-drill'
);

{
    my ( $out, $err, $code ) = _run_helper('--commands');
    is( $code, 0, '--commands exits 0' );
    like(
        $out,
        qr/PRIVATE [ ] BETA: [ ] NOT [ ] CLAIMED/msx,
        '--commands banner'
    );
    like(
        $out,
        qr/script\/staging-drill [ ] --json/msx,
        '--commands prints staging-drill'
    );
}

{
    my ( $out, $err, $code ) = _run_helper('--status');
    is( $code, 0, '--status exits 0' );
    like( $out, qr/private_beta=not-claimed/msx, '--status residual line' );
    like( $out, qr/\bok\tstaging-drill\b/msx, '--status finds staging-drill' );
}

sub _run_helper {
    my (@args)      = @_;
    my $stderr_file = path( tempdir( CLEANUP => 1 ) )->child('stderr.txt');
    my $cmd         = join q{ }, map { quotemeta } ( $HELPER, @args );
    ## no critic (InputOutput::ProhibitBacktickOperators) -- the shell redirects stderr
    my $out  = qx{$cmd 2>$stderr_file};
    my $code = $CHILD_ERROR >> $EXIT_STATUS_SHIFT;
    my $err  = -f "$stderr_file" ? $stderr_file->slurp : q{};
    return ( $out, $err, $code );
}

1;
