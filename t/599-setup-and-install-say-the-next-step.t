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

const my $NOT_ROOT     => 1_000;
const my $EXIT_FAILURE => 1;
const my $STATUS_SHIFT => 8;
const my $SECRET_CHARS => 64;
const my $DEPENDENCIES => 'script/bootstrap-deps';
const my $OK           => "\N{CHECK MARK} ";
const my $FAILED       => "\N{BALLOT X} ";

# Operator walkthrough 3, friction 13 and 4: the dependency install ends with
# the command that comes next, in the operator's language, as make
# system-perl's does; and gpforum setup says, in Italian as in English, that
# the sender it derived followed a new address, and what libpq told each
# superuser login it tried.

subtest 'make install-deps-* ends with the next step' => sub {
    my $script = path($DEPENDENCIES)->slurp;
    my ($ending) =
      $script =~ /^ ( [#] [ ] What [ ] to [ ] type [ ] next .* ) \z/msx;
    ok( defined $ending, 'the script ends with what to type next' );

    my $catalogs = GPForum::Service::I18N::CliCatalog->catalogs;
    my %english  = $script =~ /words_say [ ] (system[.]\w+) [ ] '([^']*)'/gmsx;
    is_deeply(
        [ sort keys %english ],
        [
            qw(system.deps_dry_run system.deps_for_setup system.deps_installed
              system.next_preflight system.next_setup)
        ],
        'one sentence for a production host, one for a checkout, and'
          . q{ setup's own, which installs them first}
    );
    is_deeply(
        [
            grep { ( $catalogs->{en}{$_} // q{} ) ne $english{$_} }
            sort keys %english
        ],
        [],
        q{each in en.po with the script's English}
    );
    is_deeply( [ grep { !exists $catalogs->{it}{$_} } sort keys %english ],
        [], 'and in it.po' );

    is(
        _ending( $ending, 'en_US.UTF-8', production => 1 ),
"\nNext: set this host up, with sudo @{[ path(q{.})->to_abs ]}/bin/gpforum"
          . " setup\n",
        'install-deps-production: setup, by the path that works before the'
          . ' link'
    );
    is(
        _ending( $ending, 'it_IT.UTF-8', production => 0 ),
        "\nProssimo passo: controlla l'host, con script/system-preflight\n",
        q{install-deps-postgres: the host's check, as the README goes on, in}
          . ' Italian'
    );
    is( _ending( $ending, 'en_US.UTF-8', production => 0, update => 1 ),
        q{}, q{and nothing after a maintainer's lock refresh} );
};

subtest 'in Italian: the sender that followed, and what each login was told' =>
  sub {
    my $directory = tempdir( CLEANUP => 1 );
    my $file      = "$directory/forum.env";
    path($file)
      ->spew( "GPFORUM_PUBLIC_BASE_URL=https://forum.walk3.org\n"
          . "GPFORUM_MAIL_FROM=forum\@forum.walk3.org\n" );
    my $run = _setup(
        $file,
        GPForum::Test::SetupDatabase->new(
            superuser => undef,
            error     => 'DBI connect failed: connection to server at'
              . ' "127.0.0.1", port 55433 failed: FATAL:  database "gpforum"'
              . ' does not exist',
            tried => [
                {
                    as     => 'gpicchiarelli',
                    reason => 'role "gpicchiarelli" does not exist',
                }
            ],
        ),
        '--force',
        '--public-url',
        'https://forum.gpforum-walk3.org',
    );
    is( $run->{status}, $EXIT_FAILURE, 'the database is not there to use' );
    my @lines = @{ $run->{lines} };
    is(
        ( grep { /GPFORUM_MAIL_FROM: /msx } @lines )[0],
        "${OK}GPFORUM_MAIL_FROM: forum\@forum.gpforum-walk3.org, che segue"
          . q{ l'indirizzo (era forum@forum.walk3.org)},
        'the sender follows the address, and says so'
    );
    is(
        ( grep { index( $_, $FAILED ) == 0 } @lines )[0],
        "${FAILED}database gpforum su 127.0.0.1:5432: nessun superutente di"
          . ' PostgreSQL risponde qui (gpicchiarelli: role "gpicchiarelli"'
          . ' does not exist), quindi il database del ruolo gpforum non'
          . " \N{LATIN SMALL LETTER E WITH GRAVE} creato",
        q{what libpq told the login, and the database alone left to make}
    );
    ok( ( grep { /PGUSER=postgres [ ] gpforum/msx } @lines ),
        'PGUSER offered' );
    ok(
        !( grep { /CREATE [ ] ROLE|psql-role/msx } @lines ),
        'and no CREATE ROLE for the role that logged in'
    );
  };

done_testing();

# The script's last words, run on their own with the variables the script
# set: what it prints, in the language given.
sub _ending ( $ending, $language, %set ) {
    my $program = join "\n",
      'root=' . path(q{.})->to_abs,
      "update=@{[ $set{update} // 0 ]}",
      "production=@{[ $set{production} // 0 ]}",
      $ending;
    local $ENV{LC_ALL} = $language;
    my $pid = open3( my $input, my $output, undef, 'sh', '-c', $program );
    close $input or croak "close: $OS_ERROR";
    my $text = do { local $INPUT_RECORD_SEPARATOR = undef; <$output> };
    waitpid $pid, 0;
    croak "the ending failed: $text" if $CHILD_ERROR >> $STATUS_SHIFT;

    return decode( 'UTF-8', $text // q{} );
}

sub _setup ( $file, $database, @arguments ) {
    my ( $output, $errors ) = ( q{}, q{} );
    my $status = GPForum::Command::Setup->new(
        catalog => GPForum::Service::I18N::CliCatalog->new( language => 'it' ),
        os      => GPForum::OS->from_name('linux'),
        effective_uid => $NOT_ROOT,
        host_name     => 'forum.gpforum-walk3.org',
        terminal      => GPForum::Test::SetupTerminal->new( interactive => 0 ),
        account       => GPForum::Test::SetupAccount->new,
        database      => $database,
        generate      => sub { return 'x' x $SECRET_CHARS; },
        migrate       => sub ($self) { return { status => 0 }; },
        owner_check   => sub ($self) { return 0; },
        output        => _handle( \$output ),
        prompt        => _handle( \$errors ),
      )
      ->run( '--env-file', $file, '--yes', '--database',
        'create', '--mail', 'sendmail', @arguments );

    $output = decode( 'UTF-8', $output );
    return {
        status => $status,
        lines  => [ split /\n/msx, $output ],
    };
}

sub _handle ($text) {
    open my $handle, '>>', $text or croak "output: $OS_ERROR";

    return $handle;
}

1;
