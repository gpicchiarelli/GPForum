package main;

use strict;
use warnings;

use Carp       qw(croak);
use Const::Fast;
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Test::More;

our $VERSION = '0.001';

const my $HELPER         => 'script/gpforum-macports-env';
const my $EXPECTED_TESTS => 12;

plan tests => $EXPECTED_TESTS;

ok( -x $HELPER, 'gpforum-macports-env is executable' );

my $helper_src = path($HELPER)->slurp;
like(
    $helper_src,
    qr/GPFORUM_MACPORTS_ROOT|\/opt\/local/msx,
    'helper knows MacPorts root'
);
like(
    $helper_src,
    qr/psql|pg_dump|pg_config/msx,
    'helper checks PostgreSQL client tools'
);
like(
    $helper_src,
    qr/not [ ] Darwin|skip:/msx,
    'helper skips non-Darwin hosts'
);

{
    local $ENV{GPFORUM_UNAME}         = 'Linux';
    local $ENV{GPFORUM_MACPORTS_ROOT} = '/nonexistent-macports-root';
    my ( $out, $err, $code ) = _run_helper('--exports');
    is( $code, 0,  'Linux --exports exits 0' );
    is( $out,  '', 'Linux --exports prints nothing' );
}

{
    local $ENV{GPFORUM_UNAME}         = 'Linux';
    local $ENV{GPFORUM_MACPORTS_ROOT} = '/nonexistent-macports-root';
    my ( $out, $err, $code ) = _run_helper('--check');
    is( $code, 0, 'Linux --check exits 0 (CI-safe skip)' );
    like( $out, qr/^skip:/msx, 'Linux --check prints skip line' );
}

{
    my $root   = tempdir( CLEANUP => 1 );
    my $pg_bin = path($root)->child( 'lib', 'postgresql16', 'bin' );
    $pg_bin->make_path;
    path($root)->child('bin')->make_path;
    for my $tool (qw(psql pg_dump pg_config)) {
        my $tool_path = $pg_bin->child($tool);
        $tool_path->spew("#!/bin/sh\necho $tool\n");
        chmod 0755, "$tool_path" or croak "chmod $tool_path: $!";
    }

    local $ENV{GPFORUM_UNAME}         = 'Darwin';
    local $ENV{GPFORUM_MACPORTS_ROOT} = $root;
    my ( $exports, $err, $code ) = _run_helper('--exports');
    is( $code, 0, 'Darwin mock --exports exits 0' );
    like(
        $exports,
        qr{export [ ] PATH="\Q$pg_bin\E:}msx,
        'Darwin mock --exports prepends MacPorts PostgreSQL bin'
    );

    my ( $check_out, $check_err, $check_code ) = _run_helper('--check');
    is( $check_code, 0, 'Darwin mock --check exits 0' );
    like(
        $check_out,
        qr/ok: [ ] psql [ ] ->/msx,
        'Darwin mock --check resolves psql under MacPorts'
    );
}

sub _run_helper {
    my (@args) = @_;
    my $stderr_file = path( tempdir( CLEANUP => 1 ) )->child('stderr.txt');
    my $cmd =
      join q{ }, map { quotemeta } ( $HELPER, @args );
    my $out = qx{$cmd 2>$stderr_file};
    my $code = $? >> 8;
    my $err  = -f "$stderr_file" ? $stderr_file->slurp : q{};
    return ( $out, $err, $code );
}

1;
