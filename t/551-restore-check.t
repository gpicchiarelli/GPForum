# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Digest::SHA;
use File::Temp    qw(tempdir);
use JSON::MaybeXS qw(decode_json encode_json);
use Mojo::File    qw(path);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Backup;
use GPForum::Test::BackupClients;

our $VERSION = '0.001';

const my $TAKEN         => 1_791_525_330;    # 2026-10-09T05:55:30Z
const my $DAY           => 86_400;
const my $ENTRIES       => 3;
const my $FILES         => 3;
const my $GARBAGE_LINES => 40;
const my $SHA           => 256;

# gpforum restore --check, audit item C5: whether a backup can be restored,
# without restoring it -- the manifest, each file's size and SHA-256 against
# it, pg_restore reading the dump's table of contents, tar reading the
# archive and finding as many files as the backup wrote. Each case damages a
# fresh backup one way.

my $count = 0;

delete local $ENV{PGPASSWORD};
local $ENV{GPFORUM_ENV} = 'development';

my $scratch = path( tempdir( CLEANUP => 1 ) );
my $clients = GPForum::Test::BackupClients->written_into(
    $scratch->child('clients')->make_path );
my $uploads = $scratch->child('uploads')->make_path;
my $nested  = $uploads->child('ab')->make_path;
$nested->child('one')->spew('first upload');
$uploads->child('two')->spew('second');
$uploads->child('three')->spew('third');

subtest 'a whole backup can be restored' => sub {
    my $place = _taken();
    my $check = _backup()->check($place);
    is( $check->{findings}->status, 'ok', 'every finding is ok' );
    is_deeply(
        [
            map { [ $_->{name}, $_->{message}[0] ] }
              @{ $check->{findings}->items }
        ],
        [
            [ 'manifest',        'cli.restore.manifest' ],
            [ 'database.dump',   'cli.restore.dump_ok' ],
            [ 'attachments.tar', 'cli.restore.archive_ok' ],
        ],
        'the manifest, the dump and the archive'
    );
    is( $check->{findings}->items->[1]{message}[1]{entries},
        $ENTRIES, q{pg_restore read the dump's three entries} );
    is( $check->{findings}->items->[2]{message}[1]{files},
        $FILES, q{tar read the archive's three files} );
    is(
        $check->{findings}->human_text( summary => 0 ),
        join( "\n",
            "\N{CHECK MARK} manifest: forum, taken 2026-10-09 05:55 UTC,"
              . ' schema 051',
            "\N{CHECK MARK} database.dump: 27 B, as the backup wrote it;"
              . ' pg_restore reads its 3 entries',
            "\N{CHECK MARK} attachments.tar: "
              . _backup()->size_text( -s "$place/attachments.tar" )
              . ', as the backup wrote it; 3 files',
            q{} ),
        'as the operator reads it'
    );
};

subtest 'a file changed after the backup cannot be trusted' => sub {
    my $place = _taken();
    my $dump  = path( $place, 'database.dump' );
    $dump->spew( $dump->slurp =~ tr/a/b/r );
    _fails(
        $place, 'database.dump',
        'cli.restore.checksum_differs',
        'the same size and another SHA-256'
    );

    $place = _taken();
    path( $place, 'attachments.tar' )->spew('cut');
    _fails( $place, 'attachments.tar', 'cli.restore.size_differs',
        'a file cut short' );

    $place = _taken();
    path( $place, 'database.dump' )->remove;
    _fails( $place, 'database.dump', 'cli.restore.missing', 'a file gone' );
};

subtest 'what pg_restore and tar cannot read is said' => sub {
    my $place = _taken();
    _rewrite( $place, 'database.dump', "not a dump at all\n" );
    my $item = _fails( $place, 'database.dump', 'cli.restore.dump_unreadable',
        'a dump pg_restore refuses' );
    is(
        $item->{message}[1]{reason},
        'pg_restore: error: input file does not appear to be a valid archive',
        'with what pg_restore said'
    );

    $place = _taken();
    _rewrite( $place, 'attachments.tar',
        "garbage, not a tar\n" x $GARBAGE_LINES );
    _fails(
        $place, 'attachments.tar',
        'cli.restore.archive_unreadable',
        'an archive tar refuses'
    );

    $place = _taken();
    my $manifest = decode_json( path( $place, 'manifest.json' )->slurp );
    $manifest->{files}[1]{entries} = $FILES + 1;
    path( $place, 'manifest.json' )->spew( encode_json($manifest) );
    _fails( $place, 'attachments.tar', 'cli.restore.archive_count',
        'an archive with fewer files than the backup wrote' );
};

subtest 'a directory that is not a backup offers the newest one in it' => sub {
    my $holder = $scratch->child('nightly')->make_path;
    my $backup = _backup( clock => sub { return $TAKEN } );
    $backup->take("$holder");
    my $newest =
      $backup->clock( sub { return $TAKEN + $DAY } )->take("$holder")
      ->{directory};
    $holder->child('gpforum-29991231T000000Z')->make_path;    # no manifest

    my $check = $backup->check("$holder");
    is_deeply(
        [ @{ $check->{findings}->items->[0] }{qw(status name)} ],
        [ 'degraded', 'manifest' ],
        'a directory of backups is a pointer, not a failure'
    );
    is( $check->{findings}->items->[0]{message}[0],
        'cli.restore.holds_backups', 'which says it holds backups' );
    is( $check->{latest}, $newest, 'its newest backup is offered' );
    is( scalar @{ $check->{findings}->items },
        1, 'and nothing else is checked' );

    is(
        _backup()->check("$scratch/missing")->{findings}
          ->items->[0]{message}[0],
        'cli.restore.no_directory', 'a directory that is not there'
    );
};

subtest 'a manifest gpforum did not write is refused' => sub {
    my $place = _taken();
    path( $place, 'manifest.json' )->spew('{"kind":"something-else"}');
    is( _backup()->check($place)->{findings}->items->[0]{message}[0],
        'cli.restore.bad_manifest', 'another kind of manifest' );

    path( $place, 'manifest.json' )->spew('not json');
    is( _backup()->check($place)->{findings}->items->[0]{message}[0],
        'cli.restore.bad_manifest', 'nor one that is not JSON' );

    $place = _taken();
    my $manifest = decode_json( path( $place, 'manifest.json' )->slurp );
    $manifest->{format} = 2;
    path( $place, 'manifest.json' )->spew( encode_json($manifest) );
    is( _backup()->check($place)->{findings}->items->[0]{message}[0],
        'cli.restore.newer_manifest', 'one a newer GPForum wrote' );

    $place    = _taken();
    $manifest = decode_json( path( $place, 'manifest.json' )->slurp );
    $manifest->{files}[0]{name} = '../../elsewhere/database.dump';
    path( $place, 'manifest.json' )->spew( encode_json($manifest) );
    is( _backup()->check($place)->{findings}->items->[1]{message}[0],
        'cli.restore.missing', 'and no file outside the backup is read' );
};

subtest 'a backup without attachments says so' => sub {
    my $place = _backup( GPFORUM_ATTACHMENT_ROOT => "$scratch/none" )
      ->take("$scratch/bare")->{directory};
    my $check = _backup()->check($place);
    is( $check->{findings}->status,      'degraded', 'it is not whole' );
    is( $check->{findings}->exit_status, 0, 'and can still be restored' );
    is( $check->{findings}->items->[-1]{message}[0],
        'cli.restore.no_attachments', 'having no uploads in it' );
};

subtest 'a host without pg_restore cannot say the dump reads' => sub {
    my $place  = _taken();
    my $backup = _backup();
    $backup->clients->pg_restore("$scratch/no/pg_restore");
    is( $backup->check($place)->{findings}->items->[1]{message}[0],
        'cli.restore.dump_unreadable', 'the dump is not said to be readable' );
};

done_testing;

# A fresh backup, in a directory of its own.
sub _taken {
    $count++;
    return _backup()->take("$scratch/backups-$count")->{directory};
}

sub _fails ( $place, $name, $key, $what ) {
    my $check = _backup()->check($place);
    my ($item) = grep { $_->{name} eq $name } @{ $check->{findings}->items };
    is( $check->{findings}->exit_status, 1,    "$what fails the check" );
    is( $item->{message}[0],             $key, "$what is said" );

    return $item;
}

# A file of the backup replaced, the manifest made to agree: what is left
# to fail is what reads it.
sub _rewrite ( $place, $name, $text ) {
    my $file = path( $place, $name );
    $file->spew($text);
    my $manifest = decode_json( path( $place, 'manifest.json' )->slurp );
    my ($entry) = grep { $_->{name} eq $name } @{ $manifest->{files} };
    $entry->{bytes}  = -s $file;
    $entry->{sha256} = Digest::SHA->new($SHA)->addfile("$file")->hexdigest;
    path( $place, 'manifest.json' )->spew( encode_json($manifest) );

    return;
}

sub _backup (%given) {
    my %settings =
      map { $_ => $given{$_} } grep { /\A GPFORUM_/msx } keys %given;
    local $ENV{GPFORUM_DATABASE_DSN}    = 'dbi:Pg:dbname=forum;host=db.test';
    local $ENV{GPFORUM_ATTACHMENT_ROOT} = "$uploads";
    local @ENV{ keys %settings }        = values %settings;

    return GPForum::Service::Operations::Backup->new(
        config   => GPForum::Config->from_environment,
        clients  => GPForum::Test::BackupClients->tools($clients),
        root     => "$scratch/code",
        database => {
            name   => 'forum',
            host   => 'db.test',
            port   => q{},
            server => '18.6',
            schema => '051',
        },
        catalog => GPForum::Service::I18N::CliCatalog->new( language => 'en' ),
        clock   => $given{clock} // sub { return $TAKEN },
    );
}

1;
