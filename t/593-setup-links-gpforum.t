# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Mojo::Util qw(decode);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::Setup;
use GPForum::OS;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Test::SetupAccount;
use GPForum::Test::SetupDatabase;
use GPForum::Test::SetupTerminal;

our $VERSION = '0.001';

# Walkthrough 3, friction 1: after the dependencies, the guide had the
# operator type `sudo ln -s /opt/gpforum/bin/gpforum /usr/local/bin/gpforum`
# before setup. `sudo bin/gpforum setup` now makes that link itself, so
# every command it offers next runs as printed; a gpforum already there is
# left alone.

const my $NOT_ROOT     => 1_000;
const my $SECRET_CHARS => 64;
const my $OK           => "\N{CHECK MARK} ";

subtest 'as root, gpforum is linked onto the PATH' => sub {
    my ( $code, $bin, $file ) = _layout();
    my $run = _setup( $code, $bin, $file );
    is( $run->{status}, 0, 'set up' ) or diag $run->{text};
    ok( -l "$bin/gpforum", 'a link' );
    is(
        path( readlink "$bin/gpforum" )->realpath->to_string,
        path("$code/bin/gpforum")->realpath->to_string,
        q{to this checkout's bin/gpforum}
    );
    _has( $run->{text},
        "${OK}gpforum: linked into $bin, so it runs from any directory\n",
        'said' );

    my $again = _setup( $code, $bin, $file );
    unlike(
        $again->{text},
        qr/gpforum: [ ] linked/msx,
        'run again, nothing is said of it'
    );
    like( $again->{text}, qr/Nothing [ ] changed/msx, 'nor changed' );
};

subtest 'another gpforum there is left, and said' => sub {
    my ( $code, $bin, $file ) = _layout();
    path($bin)->make_path;
    path( $bin, q{gpforum} )->spew("#!/bin/sh\n");
    my $run = _setup( $code, $bin, $file );
    is( $run->{status},                 0,             'setup goes on' );
    is( path( $bin, 'gpforum' )->slurp, "#!/bin/sh\n", 'the other is kept' );
    _has(
        $run->{text},
        "! gpforum: $bin/gpforum is another program, so this checkout's is"
          . " not linked there\n",
        'and named'
    );
    like(
        $run->{text},
qr{Fix: [ ] sudo [ ] ln [ ] -sf [ ] \S+/bin/gpforum [ ] \Q$bin\E/gpforum}msx,
        'with the command that replaces it'
    );
};

subtest 'in Italian, under --dry-run, and for anyone but root' => sub {
    my ( $code, $bin, $file ) = _layout();
    my $dry = _setup( $code, $bin, $file, language => 'it', dry_run => 1 );
    _has(
        $dry->{text},
        "${OK}gpforum: verrebbe collegato in $bin\n",
        'it says it would'
    );
    ok( !-e "$bin/gpforum", 'and does not' );

    my $user = GPForum::Command::Setup->new(
        effective_uid => $NOT_ROOT,
        os            => GPForum::OS->from_name('linux')
    );
    is( $user->links_into, undef, q{anyone else's PATH is their own} );
    is( GPForum::Command::Setup->new( effective_uid => 0 )->links_into,
        '/usr/local/bin', q{root's is /usr/local/bin} );
};

# The quick start had a macOS developer type ln -s "$PWD/bin/gpforum"
# "$(brew --prefix)/bin/" before setup, which runs there without sudo:
# Homebrew's bin is theirs, and on their PATH.
subtest q{on macOS, anyone's is Homebrew's bin, when it is theirs} => sub {
    my $prefix = path( tempdir( CLEANUP => 1 ) );
    local $ENV{HOMEBREW_PREFIX} = "$prefix";
    my $mac = sub {
        return GPForum::Command::Setup->new(
            effective_uid => $NOT_ROOT,
            os            => GPForum::OS->from_name('darwin'),
        )->links_into;
    };
    is( $mac->(), undef, 'none without a bin' );
    $prefix->child('bin')->make_path;
    is( $mac->(), "$prefix/bin", q{Homebrew's bin} );
    $prefix->child('bin')->chmod( oct '555' );
    if ( $EFFECTIVE_USER_ID != 0 ) {
        is( $mac->(), undef, 'but not one they cannot write' );
    }
    $prefix->child('bin')->chmod( oct '755' );
};

done_testing();

# A checkout with its bin/gpforum, the directory to link into, and where
# the environment file goes.
sub _layout {
    my $directory = tempdir( CLEANUP => 1 );
    my $code      = path( $directory, 'code' );
    $code->child('bin')->make_path;
    $code->child( 'bin', 'gpforum' )->spew("#!perl\n")->chmod( oct '755' );
    my $bin = path( $directory, 'local-bin' );

    return ( "$code", "$bin", "$directory/forum.env" );
}

sub _setup ( $code, $bin, $file, %options ) {
    my ( $output, $errors ) = ( q{}, q{} );
    my $status = GPForum::Command::Setup->new(
        catalog => GPForum::Service::I18N::CliCatalog->new(
            language => $options{language} // 'en'
        ),
        os            => GPForum::OS->from_name('linux'),
        effective_uid => $NOT_ROOT,
        links_into    => $bin,
        root          => path($code),
        host_name     => 'forum.walk.org',
        terminal      => GPForum::Test::SetupTerminal->new( interactive => 0 ),
        account       => GPForum::Test::SetupAccount->new,
        database      =>
          GPForum::Test::SetupDatabase->new( role => 1, database => 1 ),
        generate    => sub { return 'x' x $SECRET_CHARS; },
        migrate     => sub ($self) { return { status => 0 }; },
        owner_check => sub ($self) { return 1; },
        output      => _handle( \$output ),
        prompt      => _handle( \$errors ),
    )->run(
        '--env-file',  $file,
        '--yes',       '--environment',
        'development', '--database',
        'create',      '--mail',
        'log', ( $options{dry_run} ? '--dry-run' : () )
    );

    return { status => $status, text => decode( 'UTF-8', $output ) };
}

sub _handle ($text) {
    open my $handle, '>>', $text or croak "output: $OS_ERROR";

    return $handle;
}

sub _has ( $text, $literal, $name ) {
    return ok( index( $text, $literal ) >= 0, $name ) || diag $text;
}

1;
