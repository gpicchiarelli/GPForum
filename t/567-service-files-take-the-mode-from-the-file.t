# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp       qw(croak);
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Mojo::DOM;
use Mojo::File qw(path);
use Test::More;

our $VERSION = '0.001';

# Walkthrough 2, friction 13: the FreeBSD rc scripts passed
# GPFORUM_ENV=${gpforum_env} on daemon(8)'s command line, and the launchd
# plists set GPFORUM_ENV=production in their EnvironmentVariables, so the
# service ran in production whatever the environment file said, while
# gpforum doctor, which reads the file, said staging. Now the file's
# GPFORUM_ENV is the mode, as systemd's EnvironmentFile= wins over a unit's
# Environment=, and production -- rc.conf's gpforum_env on FreeBSD -- is
# the mode of a file that names none.

my $directory = tempdir( CLEANUP => 1 );
my $staging   = path( $directory, 'staging.env' );
$staging->spew("GPFORUM_ENV=staging\nGPFORUM_LOG_LEVEL=debug\n");
my $silent = path( $directory, 'silent.env' );
$silent->spew("GPFORUM_LOG_LEVEL=debug\n");
my $missing = path( $directory, 'missing.env' )->to_string;

for my $plist ( sort glob 'deploy/launchd/*.plist' ) {
    my $text = path($plist)->slurp('UTF-8');
    my $dom  = Mojo::DOM->new->xml(1)->parse($text);
    unlike(
        join( q{ }, map { $_->text } $dom->find('dict > key')->each ),
        qr/\b GPFORUM_ENV \b/msx,
        "$plist does not set the mode itself"
    );

    my ( $shell, $flag, $script ) =
      map { $_->text } $dom->find('key + array > string')->each;
    is( "$shell $flag", '/bin/sh -c',
        'its job starts through a shell that reads the file' );
    my $read = sub ($file) {
        my %environment = _environment( $shell, $flag, $script, $file );
        return $environment{GPFORUM_ENV};
    };
    is( $read->("$staging"), 'staging',    'the file names the mode' );
    is( $read->("$silent"),  'production', 'production when it names none' );
    is( $read->($missing),   'production', 'and when there is no file' );
}

for my $script (qw(deploy/freebsd/gpforum deploy/freebsd/gpforum_outbox)) {
    my $text = path($script)->slurp('UTF-8');
    my ($arguments) = $text =~ /^command_args="([^\n]*)"$/msx;
    unlike( $arguments // q{},
        qr/GPFORUM_ENV=/msx,
        "$script does not put the mode on daemon(8)'s command line" );

    # The lines of its load function that read the file and choose the
    # mode, run as rc runs them.
    my ($load) =
      $text =~ /^ ( [ ]{4} set [ ] -a \n .*? export [ ] GPFORUM_ENV \n )/msx;
    ok( defined $load, 'its environment file sets the mode' );
    my $read = sub ($file) {
        my %environment = _environment(
            '/bin/sh',
            '-c',
            qq{gpforum_env_file="\$0"; gpforum_env=production;\n$load}
              . 'exec "$@"',
            $file
        );
        return $environment{GPFORUM_ENV};
    };
    is( $read->("$staging"), 'staging', 'the file names the mode' );
    is( $read->("$silent"), 'production',
        q{rc.conf's gpforum_env when it names none} );
}

done_testing();

# The environment a command sees, run through the shell and script given
# with the file as $0, as launchd and rc run them.
sub _environment ( $shell, $flag, $script, $file ) {
    local %ENV = %ENV;
    delete $ENV{GPFORUM_ENV};
    open my $child, q{-|}, $shell, $flag, $script, $file, '/usr/bin/env'
      or croak "cannot run $shell: $OS_ERROR";
    my %environment = map { /\A ([^=]+) = (.*) \z/msx ? ( $1, $2 ) : () }
      map { s/\n\z//rmsx } <$child>;
    close $child or croak "the shell failed: $CHILD_ERROR";

    return %environment;
}

1;
