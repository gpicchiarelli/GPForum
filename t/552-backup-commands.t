# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;
use utf8;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use File::Temp    qw(tempdir);
use JSON::MaybeXS qw(decode_json);
use Mojo::File    qw(path);
use Mojo::Util    qw(decode);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::CLI::FrontDoor::Help;
use GPForum::Command::Backup;
use GPForum::Command::Restore;
use GPForum::Command::Support::Verbs;
use GPForum::Command::Support::Words;
use GPForum::Config;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Backup;
use GPForum::Test::BackupClients;

our $VERSION = '0.001';

const my $EXIT_OK      => 0;
const my $EXIT_FAILURE => 1;
const my $EXIT_USAGE   => 2;
const my $TAKEN        => 1_791_525_330;            # 2026-10-09T05:55:30Z
const my $PASSWORD     => 'hunter2-dsn-password';
const my $CHECK        => "\N{CHECK MARK}";

# What the operator types and reads: gpforum backup [--to DIR] and gpforum
# restore --check DIR, in English and in Italian, their exit statuses, their
# --json, and the refusals that say what to do instead. Both are verbs of
# the front door's Maintain group.

delete local $ENV{PGPASSWORD};
local $ENV{GPFORUM_ENV} = 'development';

my $scratch = path( tempdir( CLEANUP => 1 ) );
my $clients = GPForum::Test::BackupClients->written_into(
    $scratch->child('clients')->make_path );
my $code    = $scratch->child('code')->make_path;
my $uploads = $scratch->child('uploads')->make_path;
$uploads->child('one')->spew('first upload');
my $place = "$scratch/nightly/gpforum-20261009T055530Z";

subtest 'gpforum backup says what it holds, and how to check it' => sub {
    my $run = _run( 'en', 'GPForum::Command::Backup', '--to', 'nightly' );
    is( $run->{status}, $EXIT_OK, 'backed up' );
    is(
        $run->{output},
        join( "\n",
            "$CHECK database forum: 27 B, schema 051, PostgreSQL 18.6",
            "$CHECK attachments: 1 file, 12 B, from $uploads",
            "$CHECK Backed up into $place",
            'Next: check that it can be restored, with gpforum restore'
              . " --check $place",
            q{} ),
        'the database, the attachments, the directory and the next step'
    );
    is( $run->{errors}, q{}, 'nothing on standard error' );

    $run = _run( 'it', 'GPForum::Command::Backup', '--to', 'nightly' );
    is(
        $run->{output},
        join( "\n",
            "$CHECK database forum: 27 B, schema 051, PostgreSQL 18.6",
            "$CHECK allegati: 1 file, 12 B, da $uploads",
            "$CHECK Backup fatto in $place-2",
            'Prossimo passo: verifica che si possa ripristinare, con gpforum'
              . " restore --check $place-2",
            q{} ),
        'and in Italian'
    );
};

subtest 'gpforum restore --check says whether it can be restored' => sub {
    my $run = _run( 'en', 'GPForum::Command::Restore', '--check', $place );
    is( $run->{status}, $EXIT_OK, 'it can' );
    is(
        $run->{output},
        join( "\n",
            "$CHECK manifest: forum, taken 2026-10-09 05:55 UTC, schema 051",
            "$CHECK database.dump: 27 B, as the backup wrote it; pg_restore"
              . ' reads its 3 entries',
            "$CHECK attachments.tar: "
              . _size("$place/attachments.tar")
              . ', as the backup wrote it; 1 file',
            q{},
            'The backup can be restored; nothing was restored.',
            'Next: to restore it, follow the steps in'
              . ' docs/ops/backup-and-restore.md',
            q{} ),
        'each file, then the verdict and the guide'
    );

    $run = _run( 'it', 'GPForum::Command::Restore', '--check', $place );
    _has_line(
        $run->{output},
        'Il backup si può ripristinare; non è stato ripristinato nulla.',
        'and in Italian'
    );

    path( $place, 'database.dump' )->spew('PGDMP changed after the backup');
    $run = _run( 'en', 'GPForum::Command::Restore', '--check', $place );
    is( $run->{status}, $EXIT_FAILURE, 'a changed file fails it' );
    _has_line(
        $run->{output},
        "\N{BALLOT X} database.dump: 30 B, where the backup wrote 27 B:"
          . ' it was cut short or changed',
        'saying which, and how'
    );
    _has_line(
        $run->{output},
        'This backup cannot be restored as it is.',
        'that it cannot be restored'
    );
    _has_line(
        $run->{output},
        'Next: keep it as it is, and take another with gpforum backup',
        'and what to do'
    );

    $run =
      _run( 'en', 'GPForum::Command::Restore', '--check', "$scratch/nightly" );
    is( $run->{status}, $EXIT_FAILURE,
        'the directory of the backups is not a backup that can be restored' );
    is(
        ( split /\n/msx, $run->{output} )[0],
        "! manifest: $scratch/nightly holds backups, and is not one itself",
        'it opens with what the directory is, not a failure'
    );
    _has_line(
        $run->{output},
        "Next: check its newest backup, with gpforum restore --check $place-2",
        'and offers the newest backup in it'
    );
};

subtest 'both answer --json' => sub {
    my $run =
      _run( 'en', 'GPForum::Command::Backup', '--to', 'json', '--json' );
    my $document = decode_json( $run->{output} );
    is( $document->{status},         'ok',             'backed up' );
    is( $document->{command},        'gpforum-backup', 'named' );
    is( $document->{manifest}{kind}, 'gpforum-backup', 'with its manifest' );

    $run = _run( 'en', 'GPForum::Command::Restore', '--check',
        $document->{directory}, '--json' );
    my $check = decode_json( $run->{output} );
    is( $check->{status}, 'ok', 'it can be restored' );
    is_deeply(
        [ map { $_->{name} } @{ $check->{findings} } ],
        [qw(manifest database.dump attachments.tar)],
        'each finding by name'
    );
};

subtest 'what cannot be done is refused with what to do instead' => sub {
    my $run = _run( 'en', 'GPForum::Command::Backup' );
    is( $run->{status}, $EXIT_FAILURE,
        'without --to, in the code directory: refused' );
    is(
        $run->{errors},
        "$code is inside the code directory $code, which an upgrade"
          . ' replaces: name another with --to, such as --to'
          . " /var/backups/gpforum.\n",
        'naming the directory and one that would do'
    );

    $run = _run( 'en', 'GPForum::Command::Backup', 'nightly' );
    is( $run->{status}, $EXIT_USAGE, 'a word without --to is misuse' );
    _has_line(
        $run->{errors},
        q{gpforum backup takes no 'nightly': name the directory with --to}
          . ' nightly.',
        'which says how to name it'
    );

    $run = _run( 'en', 'GPForum::Command::Restore', $place );
    is( $run->{status}, $EXIT_USAGE, 'restore without --check is misuse' );
    _has_line(
        $run->{errors},
        'gpforum restore checks a backup and restores nothing: gpforum'
          . ' restore --check DIR. Restoring one is done by hand, with the'
          . ' steps in docs/ops/backup-and-restore.md.',
        'which says restoring is done by hand, and where'
    );
};

subtest 'a database that does not answer is said without its password' => sub {
    my $run = _run(
        'en',
        'GPForum::Command::Backup',
        '--to',
        'unreached',
        {
            GPFORUM_DATABASE_DSN =>
              "dbi:Pg:dbname=forum;host=127.0.0.1;port=1;password=$PASSWORD",
        }
    );
    is( $run->{status}, $EXIT_FAILURE, 'it fails' );
    like(
        $run->{errors},
        qr/\A Cannot [ ] reach [ ] PostgreSQL [ ] at [ ] 127[.]0[.]0[.]1:1/msx,
        'as every command says it'
    );
    unlike(
        $run->{output} . $run->{errors},
        qr/\Q$PASSWORD\E/msx,
        'and the password is not printed'
    );
    ok( !-e "$scratch/unreached" || !path("$scratch/unreached")->list->size,
        'and no backup is left' );
};

subtest 'the front door lists them under Maintain' => sub {
    for my $verb (qw(backup restore)) {
        is( GPForum::Command::Support::Verbs->find($verb)->{group},
            'maintain', "$verb is a Maintain verb" );
    }
    local $ENV{LC_ALL} = 'en_US.UTF-8';
    my $help = GPForum::CLI::FrontDoor::Help->new(
        words => GPForum::Command::Support::Words->new(
            catalog => GPForum::Service::I18N::CliCatalog->new(
                language => 'en'
            )
        )
    )->render;
    my %said = map { /\A \s+ (\S+) \s+ (.+) \z/msx ? ( $1 => $2 ) : () }
      split /\n/msx, $help;
    is(
        $said{backup},
        'Back up the database and the uploads',
        'gpforum help says what backup does'
    );
    is( $said{restore}, 'Check that a backup can be restored', 'and restore' );
};

done_testing;

# Whether a text has a line, whole.
sub _has_line ( $text, $line, $name ) {
    my $found = grep { $_ eq $line } split /\n/msx, $text;
    return ok( $found, $name ) || diag $text;
}

sub _size ($file) {
    return GPForum::Service::Operations::Backup->new->size_text( -s $file );
}

# A command run with this test's settings and fake clients, its output and
# errors kept, in the language asked for.
sub _run ( $language, $class, @arguments ) {
    my %settings = ref $arguments[-1] ? %{ pop @arguments } : ();
    local $ENV{GPFORUM_DATABASE_DSN}    = 'dbi:Pg:dbname=forum;host=db.test';
    local $ENV{GPFORUM_ATTACHMENT_ROOT} = "$uploads";
    local @ENV{ keys %settings }        = values %settings;
    my $catalog =
      GPForum::Service::I18N::CliCatalog->new( language => $language );
    my $backup = GPForum::Service::Operations::Backup->new(
        config  => GPForum::Config->from_environment,
        clients => GPForum::Test::BackupClients->tools($clients),
        root    => "$code",
        catalog => $catalog,
        clock   => sub { return $TAKEN },
        %settings
        ? ()
        : (
            database => {
                name   => 'forum',
                host   => 'db.test',
                port   => q{},
                server => '18.6',
                schema => '051',
            }
        ),
    );

    my $words = GPForum::Command::Support::Words->new( catalog => $catalog );
    my $from  = $class eq 'GPForum::Command::Backup'
      && !@arguments ? "$code" : "$scratch";

    return _captured(
        sub ( $out, $err ) {
            return $class->new(
                backup    => $backup,
                directory => $from,
                words     => $words,
                output    => $out,
                (
                    $class eq 'GPForum::Command::Backup'
                    ? ( errors => $err )
                    : ()
                ),
            )->run(@arguments);
        }
    );
}

# What a run printed on its two handles, standard error among them, and its
# status.
sub _captured ($code) {
    my ( $output, $errors ) = ( q{}, q{} );
    open my $out, '>', \$output or croak "cannot capture: $OS_ERROR";
    open my $err, '>', \$errors or croak "cannot capture: $OS_ERROR";
    my $status = do { local *STDERR = $err; $code->( $out, $err ) };
    close $out or croak "cannot close: $OS_ERROR";
    close $err or croak "cannot close: $OS_ERROR";

    return {
        status => $status,
        output => decode( 'UTF-8', $output ),
        errors => decode( 'UTF-8', $errors ),
    };
}

1;
