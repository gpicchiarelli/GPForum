# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::Command::Secret;
use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Support::Words;
use GPForum::OS;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::ServiceFiles;

our $VERSION = '0.001';

# ADR 0124 had the running service read its metrics tokens again from its
# environment file, and gpforum secret rotate metrics drop the restart --
# for the host's own file only. A forum set up with gpforum --env-file FILE
# kept "Next: sudo systemctl restart gpforum gpforum-outbox" after each
# rotation, although its units, printed with that --env-file, hand FILE to
# bin/gpforum, which tells the service in GPFORUM_ENV_FILE. The launchd jobs
# did not: they sourced FILE in a shell, and bin/gpforum then read the
# host's file over it. Now every web unit printed for a file names it to
# bin/gpforum, and a rotation of the file the installed unit names needs no
# restart.

const my $OTHER => '/srv/forum/forum.env';
const my $LONG  => 'x' x 64;
const my $MODE  => oct '640';

# Between two arguments: a space on a command line, a string's end and the
# next's start in a plist. And the file, as itself or as the rc variable
# that holds it.
const my $BETWEEN => qr{(?: </string> \s* <string> | [ ] )}msx;
const my $NAMED   => qr{(?: \Q$OTHER\E | [\$][{]gpforum_env_file[}] )}msx;
const my %WEB_UNIT => (
    systemd => [ 'linux',   'gpforum.service' ],
    rc      => [ 'freebsd', 'gpforum' ],
    launchd => [ 'darwin',  'com.gpforum.app.plist' ],
);

subtest 'every web unit printed for a file names it to bin/gpforum' => sub {
    for my $target ( sort keys %WEB_UNIT ) {
        my ( $os, $name ) = @{ $WEB_UNIT{$target} };
        my ($unit) = @{ _files( $os, $OTHER )->render( $target, [$name] ) };
        like(
            $unit->{text},
            qr{/bin/gpforum $BETWEEN --env-file $BETWEEN $NAMED}msx,
            "$target: bin/gpforum --env-file, for that file"
        );
    }
};

subtest 'launchd: the file, then the start, as the job runs them' => sub {
    my ($plist) = @{ _files( 'darwin', $OTHER )
          ->render( 'launchd', ['com.gpforum.app.plist'] ) };
    my @arguments = $plist->{text} =~ m{<string>([^<]*)</string>}gmsx;
    my ($at) =
      grep { $arguments[$_] =~ m{/bin/gpforum \z}msx } 0 .. $#arguments;
    is_deeply(
        [ @arguments[ $at + 1 .. $#arguments ] ],
        [ '--env-file', $OTHER, qw(start --service --foreground) ],
        'bin/gpforum --env-file FILE start --service --foreground'
    );
    is( scalar( grep { $_ eq $OTHER } @arguments ),
        2, 'the shell sources the same file, for the mode' );

    my ($own) = @{ _files( 'darwin', undef )
          ->render( 'launchd', ['com.gpforum.app.plist'] ) };
    unlike( $own->{text}, qr/--env-file/msx,
        q{the host's own file needs no --env-file: bin/gpforum reads it} );

    my ($outbox) = @{ _files( 'darwin', $OTHER )
          ->render( 'launchd', ['com.gpforum.outbox.plist'] ) };
    like(
        $outbox->{text},
        qr{--env-file $BETWEEN \Q$OTHER\E $BETWEEN outbox}msx,
        'and the outbox worker reads that file, not the host one over it'
    );
};

subtest 'a rotation of the file the installed unit names: no restart' => sub {
    my $directory = path( tempdir( CLEANUP => 1 ) );
    my $file      = $directory->child('forum.env');
    for my $target ( sort keys %WEB_UNIT ) {
        my ( $os, $name ) = @{ $WEB_UNIT{$target} };
        my ($unit) =
          @{ _files( $os, "$file" )->render( $target, [$name] ) };
        my $installed = $directory->child("$target-$name");
        $installed->spew( $unit->{text}, 'UTF-8' );

        $file->spew( path('deploy/gpforum.env.example')->slurp );
        chmod $MODE, "$file" or croak "chmod: $ERRNO";
        _rotate( $file, $installed, $os );
        my $output = _rotate( $file, $installed, $os );
        like(
            $output,
            qr/accepts [ ] both [ ] now, [ ] with [ ] no [ ] restart/msx,
            "$target: the running service accepts both"
        );
        unlike(
            $output,
            qr/restart [ ] gpforum|kickstart|service [ ] gpforum/msx,
            'and no restart is offered'
        );
    }

    my ($own) =
      @{ _files( 'linux', undef )->render( 'systemd', ['gpforum.service'] ) };
    my $installed = $directory->child('own.service');
    $installed->spew( $own->{text}, 'UTF-8' );
    like(
        _rotate( $file, $installed, 'linux' ),
        qr/^Next: [ ] sudo [ ] systemctl [ ] restart [ ] gpforum/msx,
        q{a unit printed for the host's own file: the restart, as before}
    );
};

done_testing();

sub _files ( $os, $file ) {
    return GPForum::Service::Operations::ServiceFiles->new(
        home => '/srv/forum',
        host => GPForum::Service::Operations::Host->new(
            catalog => GPForum::Service::I18N::CliCatalog->new(
                language => 'en'
            ),
            environment => 'production',
            os          => GPForum::OS->from_name($os),
        ),
        defined $file ? ( environment_file => $file ) : (),
        environment => {},
    );
}

# gpforum --env-file FILE secret rotate metrics, on a host whose web unit
# is the one given.
sub _rotate ( $file, $unit, $os ) {
    local $ENV{GPFORUM_ENV} = 'production';
    GPForum::Command::Support::ServiceEnvironment->new(
        file        => "$file",
        environment => {},
    )->load;
    my $secret = GPForum::Command::Secret->new(
        generate            => sub { state $made = 0; return $LONG . ++$made },
        web_unit            => "$unit",
        service_environment =>
          GPForum::Command::Support::ServiceEnvironment->new(
            os => GPForum::OS->from_name($os)
          ),
        words => GPForum::Command::Support::Words->new(
            catalog =>
              GPForum::Service::I18N::CliCatalog->new( language => 'en' )
        ),
    );

    my $output = q{};
    {
        open my $stdout, '>', \$output or croak 'capture stdout';
        local *STDOUT = $stdout;
        $secret->run(qw(rotate metrics));
        close $stdout or croak 'close stdout';
    }
    utf8::decode($output);

    return $output;
}

1;
