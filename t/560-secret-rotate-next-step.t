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

our $VERSION = '0.001';

# Walkthrough 2, friction 2: at DEPLOYMENT step 4, before any service file
# is in place, gpforum secret rotate session ended "Next: sudo systemctl
# restart gpforum gpforum-outbox", which answers "Unit gpforum.service not
# found" (and launchd's kickstart "Could not find service"). Until the
# service files are installed the next step is the one that installs them,
# or, in development, the server started by hand; once they are, the
# restart. Walkthrough 3, friction 7: that step was a bare gpforum service
# print, which writes every unit to the terminal; it is the --to form setup
# offers.

const my $SECRET_FILE_MODE => oct '640';
const my $LONG             => 'x' x 64;

my $directory = tempdir( CLEANUP => 1 );
my $file      = path( $directory, 'forum.env' );

subtest 'a first install is sent to the service files, not a restart' => sub {
    my $run = _rotate( 'production', 'linux', 0 );
    is( $run->{status}, 0, 'the secret is written' );
    is(
        _next( $run->{output} ),
        'Next: install and start the services, with sudo gpforum --env-file'
          . " $file service print systemd --to /etc/systemd/system",
        'and the step after writes the units where systemd reads them,'
          . ' for the file it wrote'
    );
    unlike(
        $run->{output},
        qr/systemctl [ ] restart/msx,
        'not a restart of services that do not exist'
    );

    like(
        _next( _rotate( 'production', 'darwin', 0 )->{output} ),
qr{service [ ] print [ ] launchd [ ] --to [ ] /Library/LaunchDaemons \z}msx,
'nor a launchctl kickstart on macOS: the plists, where launchd reads them'
    );
};

subtest 'development starts the server it runs by hand' => sub {
    is(
        _next( _rotate( 'development', 'darwin', 0 )->{output} ),
        "Next: start the forum, with gpforum --env-file $file start"
          . ' --foreground',
        'gpforum start --foreground, on the same file'
    );
};

subtest 'installed services are restarted, as before' => sub {
    is( _next( _rotate( 'production', 'linux', 1 )->{output} ),
        'Next: sudo systemctl restart gpforum gpforum-outbox', 'systemd' );
    like(
        _next( _rotate( 'production', 'freebsd', 1 )->{output} ),
        qr/sudo [ ] service [ ] gpforum [ ] restart/msx,
        'and rc.d'
    );
};

subtest 'in Italian' => sub {
    local $ENV{LC_ALL} = 'it_IT.UTF-8';
    is(
        _next( _rotate( 'production', 'linux', 0, 'it' )->{output} ),
'Prossimo passo: installa e avvia i servizi, con sudo gpforum --env-file'
          . " $file service print systemd --to /etc/systemd/system",
        'the same step, in the operator language'
    );
};

done_testing();

# A rotation of the session secret into a fresh copy of the template, as the
# front door runs it after reading that file.
sub _rotate ( $environment, $os, $installed, $language = 'en' ) {
    $file->spew( path('deploy/gpforum.env.example')->slurp );
    chmod $SECRET_FILE_MODE, "$file" or croak "chmod: $ERRNO";
    local $ENV{GPFORUM_ENV} = $environment;
    GPForum::Command::Support::ServiceEnvironment->new(
        file        => "$file",
        environment => {},
    )->load;

    my $secret = GPForum::Command::Secret->new(
        generate            => sub { return $LONG },
        services_installed  => $installed,
        service_environment =>
          GPForum::Command::Support::ServiceEnvironment->new(
            os => GPForum::OS->from_name($os)
          ),
        words => GPForum::Command::Support::Words->new(
            catalog =>
              GPForum::Service::I18N::CliCatalog->new( language => $language )
        ),
    );

    return _captured( sub { return $secret->run(qw(rotate session)) } );
}

sub _next ($output) {
    my ($next) = $output =~ /^ ( (?: Next | Prossimo [ ] passo ) : [^\n]* )/msx;

    return $next // q{};
}

sub _captured ($code) {
    my ( $output, $errors ) = ( q{}, q{} );
    my $status;
    {
        open my $stdout, '>', \$output or croak 'capture stdout';
        open my $stderr, '>', \$errors or croak 'capture stderr';
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        $status = $code->();
        close $stdout or croak 'close stdout';
        close $stderr or croak 'close stderr';
    }
    utf8::decode($output);

    return { errors => $errors, output => $output, status => $status };
}

1;
