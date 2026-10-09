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

const my $EXIT_FAILURE => 1;
const my $HOST         => 'forum.gpforum.net';
const my $OK           => "\N{CHECK MARK} ";
const my $FAILED       => "\N{BALLOT X} ";
const my $STAT_GID     => 5;

# What a made secret carries after its number, to be as long as production
# asks of one.
const my $LONG => q{-} . ( 'x' x 32 );

# ADR 0122, section 6: run as root on a deployed host, gpforum setup makes
# the account the services run as -- on Linux and FreeBSD with the system's
# command, on macOS it says how instead -- gives it the uploads directory,
# and gives the environment file to its group. Root is played here by an
# account double that answers with this process's own ids.

my $directory = tempdir( CLEANUP => 1 );
my $secrets   = 0;

subtest 'Linux: the account made, with its uploads directory' => sub {
    my $file    = "$directory/linux.env";
    my $account = GPForum::Test::SetupAccount->new;
    my $run     = _setup( $file, $account, 'linux' );
    is( $run->{status}, 0, 'it succeeds' ) or diag $run->{errors};
    is_deeply( $account->made, ["$directory/code"],
        'the account made, at home in the code directory' );
    ok( -d "$directory/code/var/attachments", 'its uploads directory made' );
    is(
        $run->{lines}[0],
        "${OK}account gpforum: made, with $directory/code/var/attachments"
          . ' for its uploads',
        'and said'
    );
    is(
        ( stat $file )[$STAT_GID],
        ( $account->ids )[1],
        q{the file is the account's group's to read}
    );
    _has(
        $run->{output},
        'install and start the services, with sudo gpforum --env-file'
          . " $file service print systemd --to ",
        'and the services are printed as root, the file being closed to'
          . ' others, into a directory'
    );
    is(
        $run->{lines}[-1],
        'Then: check the whole forum, with sudo -u gpforum gpforum --env-file'
          . " $file doctor",
        q{and the forum checked as the account, whose group's the file is}
    );
};

subtest 'Linux: an account that cannot be made stops setup' => sub {
    my $file = "$directory/failed.env";
    my $run  = _setup( $file,
        GPForum::Test::SetupAccount->new( fails => 'it exited 9' ), 'linux' );
    is( $run->{status}, $EXIT_FAILURE, 'it fails' );
    is_deeply(
        $run->{lines},
        [
            "${FAILED}account gpforum: could not be made (it exited 9)",
            '    Fix: sudo useradd --system gpforum',
            q{}, '1 thing to fix.',
        ],
        'naming the command, before anything is written'
    );
    ok( !-e $file, 'and the file is not written' );
};

subtest 'macOS: the account is the operator to make' => sub {
    my $file = "$directory/darwin.env";
    my $run =
      _setup( $file, GPForum::Test::SetupAccount->new( system_commands => [] ),
        'darwin' );
    is( $run->{status}, 0, 'it goes on' ) or diag $run->{errors};
    is_deeply(
        [ @{ $run->{lines} }[ 0 .. 2 ] ],
        [
            '! account gpforum: not on this host, and the services run as it',
            '    Fix: make it as docs/DEPLOYMENT.md shows for this system',
            "         then sudo gpforum --env-file $file setup again",
        ],
        'saying how, and to run setup again'
    );
    ok( -e $file, 'and writes the file all the same' );
    is(
        $run->{lines}[-1],
        "Then: check the whole forum, with sudo gpforum --env-file $file"
          . ' doctor',
        'its next steps as root, with no account to run them as'
    );
};

subtest 'run again once the group exists, the file is given to it' => sub {
    my $file    = "$directory/darwin.env";
    my $account = GPForum::Test::SetupAccount->new( exists => 1 );
    chown $EFFECTIVE_USER_ID, _other_group(), $file;
    my $run = _setup( $file, $account, 'darwin',
        GPForum::Test::SetupDatabase->new( role => 1, database => 1 ) );
    is( $run->{status}, 0, 'it succeeds' ) or diag $run->{errors};
    is(
        ( stat $file )[$STAT_GID],
        ( $account->ids )[1],
        'the file is the group of the account'
    );
    _has( $run->{lines}[1], "$OK$file: now ", 'and it says so' );
    _has( $run->{lines}[1], ', 0640, so the services can read it', 'why' );
};

done_testing();

sub _setup ( $file, $account, $os, $database = undef ) {
    my ( $output, $errors ) = ( q{}, q{} );
    my $setup = GPForum::Command::Setup->new(
        catalog => GPForum::Service::I18N::CliCatalog->new( language => 'en' ),
        os      => GPForum::OS->from_name($os),
        effective_uid => 0,
        root          => path("$directory/code"),
        host_name     => $HOST,
        account       => $account,
        terminal      => GPForum::Test::SetupTerminal->new,
        database      => $database // GPForum::Test::SetupDatabase->new,
        generate      => sub { return 'secret-' . ++$secrets . $LONG },
        migrate       => sub ($self) {
            return { status => 0, summary => 'Schema is current (051)' };
        },
        owner_check => sub ($self) { return 1; },
        output      => _handle( \$output ),
        prompt      => _handle( \$errors ),
    );
    my $status = _with_stderr(
        \$errors,
        sub {
            return $setup->run(
                '--env-file',    $file,
                '--yes',         '--public-url',
                "https://$HOST", '--database',
                'create',        '--mail',
                'sendmail'
            );
        }
    );
    $output = decode( 'UTF-8', $output );

    return {
        status => $status,
        output => $output,
        lines  => [ split /\n/msx, $output ],
        errors => decode( 'UTF-8', $errors ),
    };
}

# A group this process belongs to other than the account double's.
sub _other_group {
    my ( $primary, @groups ) = split q{ }, $EFFECTIVE_GROUP_ID;
    my ($other) = grep { $_ != $primary } @groups;

    return $other // $primary;
}

sub _with_stderr ( $errors, $code ) {
    local *STDERR = _handle($errors);

    return $code->();
}

sub _handle ($text) {
    open my $handle, '>>', $text or croak "output: $OS_ERROR";

    return $handle;
}

sub _has ( $text, $fragment, $name ) {
    ok( index( $text, $fragment ) >= 0, $name )
      or diag "looked for: $fragment\nin: $text";

    return;
}

1;
