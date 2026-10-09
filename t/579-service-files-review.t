# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;
use utf8;

use Const::Fast;
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Mojo::Util qw(encode);
use Test::More;

use lib 'lib';

use GPForum::OS;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Findings;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::ServiceFiles;
use GPForum::Service::Operations::ServiceUnits;

our $VERSION = '0.001';

# The review of the files gpforum service print writes (audit C2): doctor
# reads a unit printed for another environment file, which then changed,
# as changed, not as one that lacks its environment file; an accented
# public name is written as nginx, Caddy and certbot take it; and the
# nginx site does not call the operator's attachment store the default.

const my $ROOT => path(q{.})->to_abs->to_string;

subtest 'a unit printed for another environment file, then changed' => sub {
    my $file      = path( tempdir( CLEANUP => 1 ), 'forum.env' )->to_string;
    my $host      = _host( 'linux', $file );
    my $directory = tempdir( CLEANUP => 1 );
    my $files     = GPForum::Service::Operations::ServiceFiles->new(
        host             => $host,
        root             => $ROOT,
        environment_file => $file,
    );
    for my $unit ( @{ $files->render( 'systemd', [], $directory ) } ) {
        my $text = $unit->{text};
        if ( $unit->{name} eq 'gpforum-outbox.service' ) {
            $text =~ s/--limit [ ] 100/--limit 50/msx;
        }
        path( $unit->{path} )->spew( $text, 'UTF-8' );
    }

    my $found = _units( $host, $directory )->units( _findings() );
    my ($unit) = @{ $found->items };
    is( $unit->{status},     'degraded', 'is changed, not failing' );
    is( $unit->{message}[0], 'doctor.units_drifted_one', 'reported as drift' )
      or diag $found->human_text;

    my $outbox = path( $directory, 'gpforum-outbox.service' );
    $outbox->spew( $outbox->slurp =~ s/^EnvironmentFile=.*$//rmsx );
    my ($lacking) =
      @{ _units( $host, $directory )->units( _findings() )->items };
    is( $lacking->{status}, 'fail',
        'while one that reads no environment file still fails' );
    like( $lacking->{message}[1]{labels},
        qr/EnvironmentFile/msx, 'naming what it lacks' );
};

subtest 'an accented public name is written in its xn-- form' => sub {
    my $files = GPForum::Service::Operations::ServiceFiles->new(
        host        => _host('linux'),
        root        => $ROOT,
        found       => sub ($program) { return 1 },
        environment => {
            GPFORUM_PUBLIC_BASE_URL =>
              encode( 'UTF-8', 'https://Fòrum.Città.it/' )
        },
    );
    my $name = 'xn--frum-lqa.xn--citt-3na.it';
    my ($site) = @{ $files->render('nginx') };
    like(
        $site->{text},
        qr/^ \s* server_name [ ] \Q$name\E;/msx,
        'in the server name'
    );
    my ($certbot) = grep { /certbot/msx } @{ $files->steps('nginx') };
    is(
        $certbot,
        "sudo certbot certonly --nginx -d $name",
        'and the certificate step'
    );
};

subtest q{the nginx site does not call the operator's store the default} =>
  sub {
    my $files = GPForum::Service::Operations::ServiceFiles->new(
        host        => _host('linux'),
        root        => $ROOT,
        environment => { GPFORUM_ATTACHMENT_ROOT => '/srv/uploads' },
    );
    for my $site ( @{ $files->render('nginx') } ) {
        like(
            $site->{text},
            qr{alias [ ] /srv/uploads/;}msx,
            'the alias is the store'
        );
        unlike(
            $site->{text},
            qr{default [ ] /srv/uploads}msx,
            'which is not called the default'
        );
    }
  };

done_testing;

sub _units ( $host, $directory ) {
    return GPForum::Service::Operations::ServiceUnits->new(
        directory => $directory,
        host      => $host,
        root      => $ROOT,
        systemctl => sub { return undef },
    );
}

sub _host ( $os, $file = undef ) {
    return GPForum::Service::Operations::Host->new(
        catalog     => _catalog(),
        environment => 'production',
        os          => GPForum::OS->from_name($os),
        defined $file ? ( environment_file => $file ) : (),
    );
}

sub _catalog {
    return GPForum::Service::I18N::CliCatalog->new( language => 'en' );
}

sub _findings {
    return GPForum::Service::Operations::Findings->new( catalog => _catalog() );
}

1;
