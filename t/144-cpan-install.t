package main;

use strict;
use warnings;

use Const::Fast;
use Mojo::File qw(path);
use Test::More;

our $VERSION = '0.001';

const my $BOOTSTRAP   => 'script/bootstrap-deps';
const my $CARTON      => 'script/gpforum-carton';
const my $SYSTEM_PERL => 'script/gpforum-system-perl';
const my $MAKEFILE    => 'Makefile';
const my $CPANFILE    => 'cpanfile';

_assert_declared_sets();
_assert_bootstrap_security();
_assert_system_perl();
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
    like(
        $bootstrap,
        qr/--rebuild-local/msx,
        'bootstrap documents --rebuild-local for incomplete local/'
    );
    like(
        $bootstrap,
        qr/mv [ ]+local [ ]+"/msx,
        'rebuild-local renames local/ aside instead of deleting'
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

sub _assert_system_perl {
    my $helper    = path($SYSTEM_PERL)->slurp;
    my $bootstrap = path($BOOTSTRAP)->slurp;
    my $locator   = path($CARTON)->slurp;
    my $preflight = path('script/system-preflight')->slurp;
    my $makefile  = path($MAKEFILE)->slurp;
    my $readme    = path('README.md')->slurp;
    my $ci        = path('.github/workflows/ci.yml')->slurp;

    like(
        $helper,
        qr/perlbrew|\.plenv|asdf|custom PREFIX|Config\{prefix\}/msx,
        'system-perl helper documents and rejects version managers'
    );
    like( $helper, qr/\/usr\/bin\/perl/msx,
        'system-perl helper prefers /usr/bin/perl' );
    like( $helper, qr/\/opt\/local/msx,
        'system-perl helper accepts MacPorts /opt/local prefix' );
    like( $helper, qr/5[.]038/msx, 'system-perl helper requires Perl 5.38+' );
    like(
        $bootstrap,
        qr/gpforum-system-perl [ ] --require/msx,
        'bootstrap requires system Perl before Carton install'
    );
    unlike(
        $bootstrap,
        qr/(?:curl|wget).*perlbrew|plenv [ ]install|perlbrew [ ]install/msx,
        'bootstrap does not install a non-system Perl'
    );
    like(
        $locator,
        qr/gpforum-system-perl"? [ ] --require/msx,
        'carton locator binds to system Perl'
    );
    like(
        $preflight,
        qr/gpforum-system-perl [ ] --preflight/msx,
        'system-preflight prints perl -V evidence'
    );
    like( $makefile, qr/^system-perl:/msx, 'Makefile has system-perl target' );
    like(
        $readme,
        qr/system [ ] Perl|\/usr\/bin\/perl/msx,
        'README documents system Perl'
    );
    unlike(
        $readme,
        qr/live [ ] next [ ] to [ ] `perl` [ ] [(]perlbrew[)]/msx,
        'README no longer suggests perlbrew for Carton'
    );
    like(
        $ci,
        qr/script\/gpforum-system-perl [ ] --preflight/msx,
        'CI runs system Perl preflight'
    );
    like( $ci, qr/\/usr\/bin\/perl/msx,
        'CI installs Carton with /usr/bin/perl' );
    ok( -x $SYSTEM_PERL, 'gpforum-system-perl is executable' );

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
        $deployment,
        qr/system [ ] Perl|\/usr\/bin\/perl/msx,
        'DEPLOYMENT documents system Perl'
    );
    like(
        $deployment,
        qr/gpforum-macports-env/msx,
        'DEPLOYMENT documents MacPorts PATH helper'
    );
    unlike(
        $deployment,
        qr/live [ ] next [ ] to [ ] `perl` [ ] [(]perlbrew[)]|plenv [ ]install/msx,
        'DEPLOYMENT has no version-manager install assumptions'
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

    my $carton = path($CARTON)->slurp;
    like(
        $carton,
        qr/"\$\{1:-\}" [ ]= [ ]"exec".*local\/lib\/perl5/msx,
        'gpforum-carton can exec from local/ when Carton binary is missing'
    );
    like(
        $carton,
        qr/local\/[.]perl-shim/msx,
        'gpforum-carton pins PATH via a perl shim for Carton-less exec'
    );
    unlike(
        $carton,
        qr/^ [ ]* if [ ] [^\n]*install[^\n]*local\/lib\/perl5/msx,
        'gpforum-carton does not soft-fail carton install without Carton'
    );

    return;
}

1;
