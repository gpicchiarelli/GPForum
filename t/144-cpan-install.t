package main;

use strict;
use warnings;

use Const::Fast;
use Mojo::File qw(path);
use Test::More;

our $VERSION = '0.001';

const my $BOOTSTRAP => 'script/bootstrap-deps';
const my $CARTON    => 'script/gpforum-carton';
const my $MAKEFILE  => 'Makefile';
const my $CPANFILE  => 'cpanfile';

_assert_declared_sets();
_assert_bootstrap_security();
_assert_operator_surface();

done_testing();

sub _assert_declared_sets {
    my $cpanfile  = path($CPANFILE)->slurp;
    my $postgres  = path('cpanfile.postgres')->slurp;
    my $snapshot  = path('cpanfile.snapshot')->slurp;
    my $bootstrap = path($BOOTSTRAP)->slurp;

    like(
        $cpanfile,
        qr/feature [ ]+ 'postgres'/msx,
        'cpanfile declares the postgres Carton feature'
    );
    like(
        $cpanfile,
        qr/do [ ]+ '[.]\/cpanfile[.]postgres'/msx,
        'postgres feature loads the split cpanfile.postgres'
    );
    like(
        $postgres,
        qr/requires [ ]+ 'DBD::Pg'/msx,
        'cpanfile.postgres declares DBD::Pg'
    );
    like(
        $postgres,
        qr/requires [ ]+ 'Mojo::Pg'/msx,
        'cpanfile.postgres declares Mojo::Pg'
    );
    like(
        $snapshot,
        qr/carton [ ] snapshot [ ] format/msx,
        'cpanfile.snapshot is the Carton lockfile'
    );
    like(
        $snapshot,
        qr/^ [ ][ ] DBD-Pg-/msx,
        'snapshot pins DBD::Pg for the postgres feature'
    );
    like(
        $snapshot,
        qr/^ [ ][ ] Mojo-Pg-/msx,
        'snapshot pins Mojo::Pg for the postgres feature'
    );
    like(
        $snapshot,
        qr/^ [ ][ ] Test-PostgreSQL-/msx,
        'snapshot pins Test::PostgreSQL for the postgres feature'
    );
    like(
        $bootstrap,
        qr/--without [ ] postgres/msx,
        'bootstrap excludes the postgres feature unless requested'
    );

    return;
}

sub _assert_bootstrap_security {
    my $bootstrap = path($BOOTSTRAP)->slurp;
    my $locator   = path($CARTON)->slurp;

    like( $bootstrap, qr/--deployment/msx,
        'bootstrap uses carton install --deployment by default' );
    like(
        $bootstrap,
        qr/https:\/\/cpan[.]metacpan[.]org\//msx,
        'bootstrap defaults to the official MetaCPAN HTTPS mirror'
    );
    like( $bootstrap, qr/PERL_CARTON_MIRROR/msx,
        'bootstrap honors Carton HTTPS mirror configuration' );
    unlike(
        $bootstrap,
        qr/(?:^|\n)[ \t]*cpanm\b/msx,
        'bootstrap does not sideload distributions with cpanm'
    );
    unlike( $bootstrap, qr/--notest/msx,
        'bootstrap does not add --notest around application dists' );
    unlike(
        $bootstrap,
        qr/rm [ ]+-rf [ ]+local/msx,
        'bootstrap does not destroy local/'
    );
    unlike(
        $locator,
        qr/curl |wget /msx,
        'carton locator does not download over ad-hoc HTTP clients'
    );
    like(
        $locator,
        qr/cpanm [ ]+-M [ ]+https:\/\/cpan[.]metacpan[.]org\//msx,
        'missing Carton is installed from MetaCPAN HTTPS'
    );

    return;
}

sub _assert_operator_surface {
    my $makefile   = path($MAKEFILE)->slurp;
    my $readme     = path('README.md')->slurp;
    my $deployment = path('docs/DEPLOYMENT.md')->slurp;
    my $readiness  = path('docs/PRODUCTION_READINESS.md')->slurp;
    my $ci         = path('.github/workflows/ci.yml')->slurp;

    like( $makefile, qr/^install-deps:/msx, 'Makefile has install-deps' );
    like(
        $makefile,
        qr/^install-deps-postgres:/msx,
        'Makefile has install-deps-postgres'
    );
    like(
        $makefile,
        qr/script\/bootstrap-deps [ ]+ --postgres/msx,
        'install-deps-postgres invokes bootstrap --postgres'
    );
    like(
        $readme,
        qr/carton [ ] install [ ] --deployment/msx,
        'README documents carton --deployment'
    );
    like(
        $deployment,
        qr/carton [ ] install [ ] --deployment/msx,
        'DEPLOYMENT documents carton --deployment'
    );
    like(
        $readiness,
        qr/carton [ ] install [ ] --deployment/msx,
        'PRODUCTION_READINESS documents carton --deployment'
    );
    like(
        $ci,
        qr/script\/bootstrap-deps [ ] --postgres/msx,
        'CI still installs through bootstrap-deps --postgres'
    );
    ok( -x $BOOTSTRAP, 'bootstrap-deps is executable' );
    ok( -x $CARTON,    'gpforum-carton is executable' );

    return;
}

1;
