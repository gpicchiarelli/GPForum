# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Mojo::File qw(path);
use Mojo::Util qw(decode);
use Symbol     qw(gensym);
use Test::More;

use lib 'lib';

use GPForum::CLI::FrontDoor::Carton;

our $VERSION = '0.001';

# Walkthrough 3, friction 1: on Debian the operator typed cd, sudo make
# install-deps-production and the ln before setup, three of the 15 commands
# against 8. `sudo /opt/gpforum/bin/gpforum setup` on a fresh clone now
# installs the dependencies first, as make install-deps-production does,
# saying so, then goes on as setup; on a checkout without them, every other
# command is left to say what it would have said.

const my $STATUS_SHIFT => 8;
const my $EXIT_FAILURE => 1;
const my $BOOTSTRAP    => 'script/bootstrap-deps';

my $class = 'GPForum::CLI::FrontDoor::Carton';
my $root  = $class->root;

subtest 'gpforum setup, and nothing else, installs them first' => sub {
    is_deeply(
        [ $class->setup_install( '/usr/local/bin/gpforum', 'setup' ) ],
        [ "$root/$BOOTSTRAP", qw(--postgres --production --for-setup) ],
        'as make install-deps-production does'
    );
    is_deeply(
        [
            $class->setup_install(
                'bin/gpforum', '--env-file',
                '/srv/f.env',  qw(setup --environment development)
            )
        ],
        [ "$root/$BOOTSTRAP", qw(--postgres --for-setup) ],
        'with the development tools for --environment development,'
          . ' after the front door\'s --env-file'
    );
    is_deeply(
        [
            $class->setup_install(
                'gpforum', qw(setup --environment=staging --dry-run)
            )
        ],
        [
            "$root/$BOOTSTRAP",
            qw(--postgres --production --for-setup --dry-run)
        ],
        'and installing nothing under --dry-run'
    );
    for my $other (
        [ 'gpforum',             'migrate' ],
        [ 'gpforum',             qw(setup --help) ],
        [ 'gpforum',             '--help' ],
        [ 'bin/gpforum-migrate', 'setup' ],
        ['gpforum'],
      )
    {
        is_deeply( [ $class->setup_install( @{$other} ) ],
            [], "not for: @{$other}" );
    }
};

subtest 'a checkout without them: setup says what it installs' => sub {
    my $clone = path( _checkout() )->realpath->to_string;
    for my $case (
        [
            'en_US.UTF-8',
            "gpforum setup installs the dependencies into $clone/local first,"
              . ' as make install-deps-production does: carton install'
              . ' --deployment --without develop',
            'Nothing was installed: --dry-run says what setup would do.',
        ],
        [
            'it_IT.UTF-8',
            "gpforum setup installa prima le dipendenze in $clone/local, come"
              . ' fa make install-deps-production: carton install'
              . ' --deployment --without develop',
            "Non \N{LATIN SMALL LETTER E WITH GRAVE} stato installato nulla:"
              . ' --dry-run dice cosa farebbe setup.',
        ],
      )
    {
        my ( $language, $installs, $nothing ) = @{$case};
        my $run = _run( $clone, $language, qw(setup --dry-run) );
        is( $run->{status}, $EXIT_FAILURE, "$language: --dry-run stops" );
        _has( $run->{output}, "$installs\n",
            'saying what setup installs first' )
          or diag $run->{errors};
        _has( $run->{output}, "$nothing\n", 'and that nothing was installed' );
        ok( !-e "$clone/local", 'nothing was' );
    }

    my $other = _run( $clone, 'en_US.UTF-8', 'migrate' );
    isnt( $other->{status}, 0, 'gpforum migrate there stops' );
    unlike(
        $other->{output},
        qr/installs [ ] the [ ] dependencies/msx,
        'without installing anything'
    );
};

done_testing();

# A checkout of this one without local/: the front door, the code, the
# scripts that install, the catalogs and the locks, and a pg_config that
# needs no PostgreSQL.
sub _checkout {
    my $clone = tempdir( CLEANUP => 1 );
    for my $kept (
        qw(bin/gpforum cpanfile cpanfile.postgres cpanfile.snapshot
        script/bootstrap-deps script/gpforum-carton script/gpforum-system-perl
        script/lib/words.sh locale/cli/en.po locale/cli/it.po)
      )
    {
        my $copy = path( $clone, $kept );
        $copy->dirname->make_path;
        path($kept)->copy_to($copy)->chmod( ( stat $kept )[2] & oct '7777' );
    }
    path( $clone, 'lib' )->make_path;
    _copy_tree( 'lib', "$clone/lib" );
    my $pg_config = path( $clone, 'pg_config' );
    $pg_config->spew("#!/bin/sh\necho /usr\n");
    $pg_config->chmod( oct '755' );

    return $clone;
}

sub _copy_tree ( $from, $to ) {
    path($from)->list_tree->each(
        sub ( $file, @ ) {
            my $copy = path( $to, $file->to_rel($from) );
            $copy->dirname->make_path;
            $file->copy_to($copy);
        }
    );

    return;
}

sub _run ( $clone, $language, @arguments ) {
    my %clean = map { $_ => $ENV{$_} }
      grep { !/\A (?: GPFORUM_ | PERL5LIB \z | PERL_ | LC_ | LANG )/msx }
      keys %ENV;
    my ( $output, $errors ) = ( q{}, gensym );
    my $pid;
    {
        local %ENV = (
            %clean,
            LC_ALL            => $language,
            GPFORUM_PG_CONFIG => "$clone/pg_config",
        );
        $pid = open3( my $input, my $out, $errors, $EXECUTABLE_NAME,
            "$clone/bin/gpforum", @arguments );
        close $input or croak "close: $OS_ERROR";
        local $INPUT_RECORD_SEPARATOR = undef;
        $output = <$out> // q{};
    }
    my $said = do { local $INPUT_RECORD_SEPARATOR = undef; <$errors> }
      // q{};
    waitpid $pid, 0;

    return {
        status => $CHILD_ERROR >> $STATUS_SHIFT,
        output => decode( 'UTF-8', $output . $said ),
        errors => $said,
    };
}

sub _has ( $text, $literal, $name ) {
    return ok( index( $text, $literal ) >= 0, $name ) || diag $text;
}

1;
