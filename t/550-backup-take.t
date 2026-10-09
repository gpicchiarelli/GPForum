# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Archive::Tar;
use Const::Fast;
use Digest::SHA   qw(sha256_hex);
use English       qw(-no_match_vars);
use File::Temp    qw(tempdir);
use JSON::MaybeXS qw(decode_json);
use Mojo::File    qw(path);
use Test::Fatal   qw(exception);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Backup;
use GPForum::Test::BackupClients;
use GPForum::X::Unavailable;

our $VERSION = '0.001';

const my $PRIVATE_DIR => oct '700';
const my $PRIVATE     => oct '600';
const my $MODE_BITS   => oct '7777';
const my $TAKEN       => 1_791_525_330;              # 2026-10-09T05:55:30Z
const my $PASSWORD    => 'sekrit-backup-password';
const my $FILES       => 3;
const my $BYTES       => 812;
const my $KILOBYTES   => 253_832;
const my $GIGABYTES   => 5_368_709_120;

# gpforum backup, audit item C5 (owner decision D11): the database as
# pg_dump's custom format, the attachment root as a tar and a manifest of
# their versions, sizes and SHA-256, in a directory named for the instant
# and readable by its owner alone. pg_dump is a fake that keeps what it was
# given; tar is the host's.

delete local $ENV{PGPASSWORD};
local $ENV{GPFORUM_ENV} = 'development';

my $scratch = path( tempdir( CLEANUP => 1 ) );
my $clients = GPForum::Test::BackupClients->written_into(
    $scratch->child('clients')->make_path );
my $code     = $scratch->child('code')->make_path;
my $uploads  = $scratch->child('uploads')->make_path;
my $backups  = $scratch->child('backups');
my $database = {
    name   => 'forum',
    host   => 'db.test',
    port   => '6543',
    server => '18.6',
    schema => '051',
};
my $nested = $uploads->child('ab/cd')->make_path;
$nested->child('one')->spew('first upload');
$uploads->child('ab/two')->spew('second');

subtest 'a backup is a dated directory of three files, for its owner' => sub {
    my $backup = _backup();
    my $taken  = $backup->take("$backups");

    is(
        $taken->{directory},
        "$backups/gpforum-20261009T055530Z",
        'named for the instant, in UTC'
    );
    my $place = path( $taken->{directory} );
    is_deeply(
        [ sort map { $_->basename } $place->list->each ],
        [qw(attachments.tar database.dump manifest.json)],
        'the dump, the archive and the manifest'
    );
    is( ( stat $place )[2] & $MODE_BITS,
        $PRIVATE_DIR, 'the directory is its owner\'s alone' );
    is_deeply(
        [ map { (stat)[2] & $MODE_BITS } $place->list->each ],
        [ ($PRIVATE) x $FILES ],
        'and so is every file in it'
    );

    is_deeply(
        [ split /\n/msx, $clients->{log}->child('pg_dump.args')->slurp ],
        [
            '--format=custom',        "--file=$place/database.dump",
            '--host=db.test',         '--port=6543',
            '--username=backup_role', 'forum',
        ],
        q{pg_dump writes the settings' database as the settings' role}
    );
    is( $clients->{log}->child('pg_dump.password')->slurp,
        $PASSWORD, 'given their password' );
    is( $ENV{PGPASSWORD}, undef, 'which is not left in the environment' );

    is_deeply(
        [
            sort grep { !m{/\z}msx }
              Archive::Tar->list_archive("$place/attachments.tar")
        ],
        [ './ab/cd/one', './ab/two' ],
        'the archive holds the attachment root, relative to it'
    );
};

subtest 'the manifest says what each file is, and never the password' => sub {
    my $taken = _backup()->take("$backups");
    my $place = path( $taken->{directory} );
    my $text  = $place->child('manifest.json')->slurp;
    my $read  = decode_json($text);

    is_deeply( $read, $taken->{manifest}, 'the manifest returned is written' );
    is( $read->{kind},   'gpforum-backup',       'it names itself' );
    is( $read->{format}, 1,                      'and its format' );
    is( $read->{taken},  '2026-10-09T05:55:30Z', 'when it was taken' );
    is_deeply(
        $read->{versions},
        { schema => '051', postgresql => '18.6', pg_dump => '18.6' },
        'the versions it came from'
    );
    is_deeply( $read->{database}, $database, 'the database it holds' );
    is_deeply(
        $read->{attachments},
        { root => "$uploads", files => 2, bytes => 18 },
        'what the attachment root held'
    );

    for my $file ( @{ $read->{files} } ) {
        my $on_disk = $place->child( $file->{name} );
        is( $file->{bytes}, -s $on_disk, "$file->{name}'s size" );
        is(
            $file->{sha256},
            sha256_hex( $on_disk->slurp ),
            "$file->{name}'s SHA-256"
        );
    }
    is( $read->{files}[1]{entries}, 2, q{the archive's files, counted} );
    unlike( $text, qr/\Q$PASSWORD\E/msx, 'the password is nowhere in it' );
    isnt(
        $taken->{directory},
        "$backups/gpforum-20261009T055530Z",
        'a second backup in the same second'
    );
    like(
        $taken->{directory},
        qr{/gpforum-20261009T055530Z-2\z}msx,
        'gets a second name'
    );
};

subtest 'without an attachment root, the backup says it has none' => sub {
    my $backup =
      _backup( GPFORUM_ATTACHMENT_ROOT => "$scratch/no-uploads-here" );
    my $taken = $backup->take( $scratch->child('elsewhere')->to_string );

    is( $taken->{manifest}{attachments}, undef, 'no attachments' );
    is_deeply( [ map { $_->{name} } @{ $taken->{manifest}{files} } ],
        ['database.dump'], 'and only the dump' );
};

subtest 'a relative attachment root starts at the code directory' => sub {
    is(
        _backup( GPFORUM_ATTACHMENT_ROOT => 'var/attachments/' )
          ->attachment_root,
        "$code/var/attachments",
        'as the units run from it'
    );
};

subtest 'a backup that fails half-way leaves nothing behind' => sub {
    my $failing = $scratch->child('failing')->make_path;
    my $script  = $failing->child('pg_dump');
    $script->spew( "#!/bin/sh\necho 'pg_dump: error: connection to server"
          . q{ at "db.test", port 6543 failed: FATAL:  password}
          . qq{ authentication failed for user "backup_role"' >&2\nexit 1\n} );
    $script->chmod( oct '755' );
    my $backup = _backup();
    $backup->clients->pg_dump("$script");
    my $into = $scratch->child('failed');

    my $error = exception { $backup->take("$into") };
    ok( GPForum::X::Unavailable->caught($error), 'pg_dump failing fails it' );
    like(
        "$error",
        qr/password [ ] authentication [ ] failed/msx,
        'with what pg_dump said'
    );
    unlike( "$error", qr/\Q$PASSWORD\E/msx, 'and not the password' );
    is_deeply( [ $into->list( { dir => 1 } )->each ],
        [], 'the half-made backup is removed' );
};

subtest 'no backup goes into the code directory or the attachments' => sub {
    my $backup = _backup();
    is_deeply(
        $backup->refusal("$code"),
        [ 'cli.backup.in_code', { directory => "$code", root => "$code" } ],
        'the code directory, which an upgrade replaces'
    );
    is( $backup->refusal("$code/backups/nightly")->[0],
        'cli.backup.in_code', 'nor a directory under it, made or not' );
    symlink "$code", "$scratch/code-link" or croak "symlink: $OS_ERROR";
    is( $backup->refusal("$scratch/code-link/backups")->[0],
        'cli.backup.in_code', 'nor through a symbolic link' );
    is( $backup->refusal("$uploads/backups")->[0],
        'cli.backup.in_attachments', 'nor inside the attachment root' );
    is( $backup->refusal("$uploads/ab/two")->[0],
        'cli.backup.not_directory', 'and a file is not a directory' );
    is( $backup->refusal("$scratch/code-sibling"),
        undef, 'a directory beside the code directory is fine' );
};

subtest 'the directory is made for its owner, or says why not' => sub {
    my $backup = _backup();
    my $into   = $scratch->child('made/for/backups');
    is( $backup->make_room("$into"),    undef,        'made' );
    is( ( stat $into )[2] & $MODE_BITS, $PRIVATE_DIR, 'readable by its owner' );

    my $locked = $scratch->child('locked')->make_path;
    chmod oct '500', "$locked" or croak "chmod: $OS_ERROR";
    my $refused = $backup->make_room("$locked/backups");
  SKIP: {
        if ( !$EFFECTIVE_USER_ID ) {
            skip 'root writes into any directory', 2;
        }
        is( $refused->[0], 'cli.backup.cannot_make', 'refused' );
        like(
            $refused->[1]{reason},
            qr/\A Permission [ ] denied \z/msx,
            'with the reason alone, not mkdir and the path again'
        );
    }
    chmod oct '700', "$locked" or croak "chmod: $OS_ERROR";
};

subtest 'sizes read as an operator reads them' => sub {
    my $backup = _backup();
    is( $backup->size_text($BYTES),     '812 B',    'bytes' );
    is( $backup->size_text($KILOBYTES), '247.9 KB', 'kilobytes' );
    is( $backup->size_text($GIGABYTES), '5.0 GB',   'gigabytes' );
    my $italian = GPForum::Service::Operations::Backup->new(
        catalog => GPForum::Service::I18N::CliCatalog->new( language => 'it' )
    );
    is( $italian->size_text($KILOBYTES),
        '247,9 KB', 'a decimal comma in Italian' );
};

done_testing;

# The service as the settings name it, with fake clients and a fixed clock.
sub _backup (%settings) {
    local $ENV{GPFORUM_DATABASE_DSN} =
      'dbi:Pg:dbname=forum;host=db.test;port=6543';
    local $ENV{GPFORUM_DATABASE_USER}     = 'backup_role';
    local $ENV{GPFORUM_DATABASE_PASSWORD} = $PASSWORD;
    local $ENV{GPFORUM_ATTACHMENT_ROOT}   = "$uploads";
    local @ENV{ keys %settings }          = values %settings;

    return GPForum::Service::Operations::Backup->new(
        config   => GPForum::Config->from_environment,
        clients  => GPForum::Test::BackupClients->tools($clients),
        root     => "$code",
        database => { %{$database} },
        clock    => sub { return $TAKEN },
    );
}

1;
