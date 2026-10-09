# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use Cwd        qw(getcwd realpath);
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Mojo::Util qw(decode);
use Symbol     qw(gensym);
use Test::More;

use lib 'lib';

use GPForum::CLI::FrontDoor::Launcher;

our $VERSION = '0.001';

const my $STATUS_SHIFT => 8;

# gpforum setup is the first verb of the Set up group, and it writes the
# environment file rather than reading it: a file named with --env-file need
# not exist yet, and one named relative to where the operator typed it is
# the one written, though the front door runs setup from the code directory.

my $root = getcwd();

subtest 'the help lists setup first, in both languages' => sub {
    my $english = _in_process( { LC_ALL => 'en_US.UTF-8' } );
    like(
        $english->{output},
        qr/^Set [ ] up\n [ ]{2} setup [ ]+ Set [ ] this [ ] host [ ] up:/msx,
        'first under Set up, with its line'
    );
    my $italian = _in_process( { LC_ALL => 'it_IT.UTF-8' } );
    like(
        decode( 'UTF-8', $italian->{output} ),
        qr/^Installazione\n [ ]{2} setup [ ]+ Prepara [ ] questo [ ] host/msx,
        'and in Italian'
    );
    my $help = _in_process( { LC_ALL => 'en_US.UTF-8' }, 'help', 'setup' );
    like(
        $help->{output},
        qr/\A Usage: [ ] gpforum [ ] setup [ ]/msx,
        'gpforum help setup is its usage'
    );
};

subtest 'a file named with --env-file need not exist yet' => sub {
    my $directory = realpath( tempdir( CLEANUP => 1 ) );
    my @answers   = (
        '--dry-run',     '--yes',
        '--environment', 'development',
        '--database',    'dbi:Pg:dbname=gpforum;host=127.0.0.1;port=1',
    );

    my $before =
      _started( $directory, '--env-file', 'new.env', 'setup', @answers );
    is( $before->{status}, 0, 'named before the verb, setup runs' )
      or diag $before->{errors};
    ok(
        index( $before->{output},
            "\N{CHECK MARK} $directory/new.env: would be written" ) == 0,
        'on the file named, from where it was typed'
    ) or diag $before->{output};

    my $after =
      _started( $directory, 'setup', '--env-file', 'new.env', @answers );
    is( $after->{status}, 0, 'and named after it' ) or diag $after->{errors};
    ok( index( $after->{output}, "$directory/new.env: would" ) > 0,
        'the same file' );
    ok( !-e "$directory/new.env", 'and --dry-run wrote nothing' );
};

done_testing();

sub _in_process ( $environment, @arguments ) {
    my ( $output, $errors ) = ( q{}, q{} );
    my $status;
    {
        local @ENV{ keys %{$environment} } = values %{$environment};
        local *STDOUT                      = _handle( \$output );
        local *STDERR                      = _handle( \$errors );
        $status = GPForum::CLI::FrontDoor::Launcher->new->run(@arguments);
    }
    chdir $root or croak "chdir: $OS_ERROR";

    return { errors => $errors, output => $output, status => $status };
}

sub _handle ($text) {
    open my $handle, '>>', $text or croak "capture: $OS_ERROR";

    return $handle;
}

# bin/gpforum started from a directory as an operator starts it, with
# GPFORUM_* cleared.
sub _started ( $directory, @arguments ) {
    my %clean = map { $_ => $ENV{$_} } grep { !/\A GPFORUM_/msx } keys %ENV;
    my ( $pid, $output, $errors );
    {
        local %ENV = ( %clean, LC_ALL => 'en_US.UTF-8' );
        chdir $directory or croak "chdir: $OS_ERROR";
        $errors = gensym;
        $pid    = open3( my $input, $output, $errors, $EXECUTABLE_NAME,
            "$root/bin/gpforum", @arguments );
        close $input or croak "close child input: $OS_ERROR";
        chdir $root  or croak "chdir: $OS_ERROR";
    }
    my %read;
    for my $stream ( [ output => $output ], [ errors => $errors ] ) {
        local $INPUT_RECORD_SEPARATOR = undef;
        my $handle = $stream->[1];
        $read{ $stream->[0] } = decode( 'UTF-8', <$handle> // q{} );
    }
    waitpid $pid, 0;

    return { %read, status => $CHILD_ERROR >> $STATUS_SHIFT };
}

1;
