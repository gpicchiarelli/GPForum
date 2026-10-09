# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use English    qw(-no_match_vars);
use Mojo::File qw(path tempdir);
use Test::More;

use lib 'lib';

our $VERSION = '0.001';

const my $WRITABLE  => oct '0755';
const my $READ_ONLY => oct '0555';

# docs/DEPLOYMENT.md keeps the code tree root's, so the service cannot
# rewrite it, and the gpforum user runs every command through
# script/gpforum-carton exec. That wrapper makes its interpreter shim in
# local/ the first time it runs; made by the service user, who cannot write
# local/, it failed with "mkdir: ... Permission denied" on stderr at every
# start and every command. The installer now makes it.

if ( $EFFECTIVE_USER_ID == 0 ) {
    plan skip_all => 'root writes local/ whatever its mode';
}

subtest 'the installer makes the shim after the install' => sub {
    my $script = path('script/bootstrap-deps')->slurp;
    my $check  = index $script, 'script/gpforum-carton check';
    my $shim   = index $script, 'script/gpforum-carton exec perl -e 1';
    ok( $shim > $check && $check > 0,
        'bootstrap-deps runs gpforum-carton exec once the lock is checked' );
};

subtest 'a user who cannot write local/ then runs quietly' => sub {
    my $installed = _checkout();
    is( _stderr($installed), q{}, 'the installer runs it' );
    $installed->child('local')->chmod($READ_ONLY);
    is( _stderr($installed), q{},
        'the service user, who cannot write local/, runs it quietly' );
    $installed->child('local')->chmod($WRITABLE);

    my $fresh = _checkout();
    $fresh->child('local')->chmod($READ_ONLY);
    like(
        _stderr($fresh),
        qr/Permission [ ] denied/msx,
        'without the installer making it, the same run complains'
    );
    $fresh->child('local')->chmod($WRITABLE);
};

done_testing();

# A tree with the wrapper, its interpreter check and an empty local/.
sub _checkout {
    my $root = tempdir;
    $root->child('script')->make_path;
    $root->child( 'local', 'lib', 'perl5' )->make_path;
    for my $name (qw(gpforum-carton gpforum-system-perl)) {
        path( 'script', $name )
          ->copy_to( $root->child( 'script', $name ) )
          ->chmod($WRITABLE);
    }

    return $root;
}

# What `gpforum-carton exec perl -e 1` printed on stderr in that tree.
sub _stderr ($root) {
    my $wrapper = $root->child( 'script', 'gpforum-carton' );
    my $errors  = $root->child('stderr.txt');
    system 'sh', '-c', qq{"$wrapper" exec perl -e 1 2>"$errors"};

    return $errors->slurp;
}

1;
