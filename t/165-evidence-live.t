package main;

use strict;
use warnings;

use Const::Fast;
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Test::More;

our $VERSION = '0.001';

const my $HELPER         => 'script/gpforum-evidence-live';
const my $EXPECTED_TESTS => 13;

plan tests => $EXPECTED_TESTS;

ok( -x $HELPER, 'gpforum-evidence-live is executable' );

my $src = path($HELPER)->slurp;
like(
    $src,
    qr/NOT CLAIMED|not-claimed/msx,
    'helper refuses to claim private-beta readiness'
);
like(
    $src,
    qr/staging-host-verify|stress-load|mail-check|mail-lifecycle|dead-letter/msx,
    'helper lists live verify, stress, mail, and ops-check tools'
);
unlike(
    $src,
    qr/exec [ ] script\/stress-load|exec [ ] script\/staging-host-verify/msx,
    'helper does not exec stress-load or staging-host-verify'
);

{
    my ( $out, $err, $code ) = _run_helper('--commands');
    is( $code, 0, '--commands exits 0' );
    like( $out, qr/PRIVATE [ ] BETA: [ ] NOT [ ] CLAIMED/msx, '--commands banner' );
    like( $out, qr/script\/staging-host-verify [ ] --json/msx,
        '--commands prints staging-host-verify' );
    like( $out, qr/gpforum-mail-lifecycle-check/msx,
        '--commands prints mail-lifecycle-check' );
    like( $out, qr/gpforum-dead-letter-check/msx,
        '--commands prints dead-letter-check' );
}

{
    my ( $out, $err, $code ) = _run_helper('--status');
    is( $code, 0, '--status exits 0' );
    like( $out, qr/private_beta=not-claimed/msx, '--status residual line' );
    like( $out, qr/\bok\tstaging-host-verify\b/msx,
        '--status finds staging-host-verify' );
    like( $out, qr/\bok\tmail-lifecycle-check\b/msx,
        '--status finds mail-lifecycle-check' );
}

sub _run_helper {
    my (@args) = @_;
    my $stderr_file = path( tempdir( CLEANUP => 1 ) )->child('stderr.txt');
    my $cmd = join q{ }, map { quotemeta } ( $HELPER, @args );
    ## no critic (InputOutput::ProhibitBacktickOperators)
    my $out  = qx{$cmd 2>$stderr_file};
    my $code = $? >> 8;
    my $err  = -f "$stderr_file" ? $stderr_file->slurp : q{};
    return ( $out, $err, $code );
}

1;
