# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;
use utf8;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use File::Temp    qw(tempdir);
use JSON::MaybeXS qw(decode_json encode_json);
use Mojo::File    qw(path);
use Mojo::Util    qw(decode);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::Backup;
use GPForum::Command::Restore;
use GPForum::Command::Support::Words;
use GPForum::Config;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Backup;
use GPForum::Service::Operations::Host;
use GPForum::Test::BackupClients;

our $VERSION = '0.001';

const my $EXIT_FAILURE => 1;
const my $TAKEN        => 1_791_525_330;    # 2026-10-09T05:55:30Z
const my $SHUT         => oct '000';
const my $OPEN         => oct '700';
const my $CROSS        => "\N{BALLOT X}";

# The review of gpforum backup and gpforum restore --check, as an operator
# meets them: a backup checked by an account that cannot read it -- the
# directory of the backups is 0700 and gpforum's -- is said with the
# account that can, not as "not a backup" or a Perl error; a manifest that
# leaves out a file is not a whole backup; pg_dump and tar failing are said
# in a sentence, without pg_dump's command line or a Perl warning; a path a
# shell would split is quoted in the command offered; and under sudo -u the
# check offered runs as the account that took the backup.

delete local $ENV{PGPASSWORD};
delete local $ENV{SUDO_USER};
local $ENV{GPFORUM_ENV} = 'development';

my $scratch = path( tempdir( CLEANUP => 1 ) );
my $clients = GPForum::Test::BackupClients->written_into(
    $scratch->child('clients')->make_path );
my $code    = $scratch->child('code')->make_path;
my $uploads = $scratch->child('uploads')->make_path;
$uploads->child('one')->spew('first upload');
my $me    = getpwuid $EFFECTIVE_USER_ID;
my $count = 0;

subtest 'a backup this account cannot read is said with the one that can' =>
  sub {
    _unless_root();

    my $holder = $scratch->child('nightly')->make_path;
    my $place  = _backup('en')->take("$holder")->{directory};
    my $check  = "sudo -u $me gpforum restore --check $place";

    chmod $SHUT, $place or croak "chmod: $OS_ERROR";
    my $run = _run( 'en', 'GPForum::Command::Restore', '--check', $place );
    is( $run->{status}, $EXIT_FAILURE, 'a backup it cannot open fails' );
    is(
        $run->{output},
        "$CROSS manifest: $me cannot read $place: check the backup as its"
          . " owner, $me, with $check\n",
        'saying who can read it, and the check as them'
    );
    is( $run->{errors}, q{}, 'not as a Perl error' );
    chmod $OPEN, $place or croak "chmod: $OS_ERROR";

    chmod $SHUT, "$holder" or croak "chmod: $OS_ERROR";
    $run = _run( 'it', 'GPForum::Command::Restore', '--check', $place );
    is(
        $run->{output},
        "$CROSS manifest: $me non può leggere $place: verifica il backup"
          . " come il suo proprietario, $me, con $check\n",
        'nor as "there is none" when the directory of the backups is shut,'
          . ' in Italian too'
    );
    chmod $OPEN, "$holder" or croak "chmod: $OS_ERROR";

    chmod $SHUT, "$place/database.dump" or croak "chmod: $OS_ERROR";
    $run = _run( 'en', 'GPForum::Command::Restore', '--check', $place );
    is( $run->{status}, $EXIT_FAILURE, 'a file it cannot read fails' );
    _has_line(
        $run->{output},
        "$CROSS database.dump: $me cannot read it: check the backup as its"
          . " owner, $me, with $check",
        'saying who can read it'
    );
    unlike(
        $run->{output},
        qr/cannot [ ] be [ ] restored | take [ ] another/msx,
        'and not that the backup is lost'
    );
    chmod oct '600', "$place/database.dump" or croak "chmod: $OS_ERROR";
  };

subtest 'a manifest that leaves a file out is not a whole backup' => sub {
    my $place = _taken();
    _manifest( $place, sub ($manifest) { $manifest->{files} = [] } );
    my $check = _backup('en')->check($place);
    is( $check->{findings}->exit_status, 1, 'an empty list fails' );
    is_deeply(
        [
            map  { [ $_->{name}, $_->{message}[0] ] }
            grep { $_->{status} eq 'fail' } @{ $check->{findings}->items }
        ],
        [
            [ 'database.dump',   'cli.restore.not_listed' ],
            [ 'attachments.tar', 'cli.restore.not_listed' ],
        ],
        'naming the dump and the archive of the uploads it says it copied'
    );
    is( $check->{findings}->items->[1]{message}[1]{file},
        'database.dump', 'by name' );

    $place = _taken();
    _manifest( $place, sub ($manifest) { $manifest->{database} = 'forum' } );
    is( _backup('en')->check($place)->{findings}->items->[0]{message}[0],
        'cli.restore.bad_manifest', 'a manifest of another shape is refused' );

    $place = _taken();
    _manifest( $place, sub ($manifest) { $manifest->{files} = ['x'] } );
    is( _backup('en')->check($place)->{findings}->items->[0]{message}[0],
        'cli.restore.bad_manifest', 'and so is a list of names' );
};

subtest 'pg_dump failing is said in a sentence, without its command line' =>
  sub {
    my $older = _client(
        'pg_dump-16',
        'pg_dump: error: aborting because of server version mismatch',
        'pg_dump: detail: server version: 18.6 (Debian 18.6-1.pgdg13+1);'
          . ' pg_dump version: 16.4 (Debian 16.4-1)'
    );
    my $into = $scratch->child('older');
    is(
        _failure( 'en', $older, $into ),
        'pg_dump 16.4 cannot back up PostgreSQL 18.6, which is newer: install'
          . q{ PostgreSQL 18's client programs, or name their pg_dump with}
          . ' GPFORUM_PG_DUMP.',
        'a pg_dump older than the server, with the client to install'
    );
    is(
        _failure( 'it', $older, $into ),
        'pg_dump 16.4 non può fare il backup di PostgreSQL 18.6, che è più'
          . ' recente: installa i programmi client di PostgreSQL 18, o indica'
          . ' il loro pg_dump con GPFORUM_PG_DUMP.',
        'in Italian too'
    );

    my $denied = _client( 'pg_dump-denied',
            'pg_dump: error: query failed: ERROR:  permission denied for table'
          . ' posts' );
    my $said = _failure( 'en', $denied, $into );
    is(
        $said,
        'pg_dump could not back up the database forum: query failed: ERROR: '
          . ' permission denied for table posts',
        'any other failure, in what pg_dump said'
    );
    unlike( $said, qr/--file|--username/msx, 'not its command line' );
    is_deeply( [ $into->list( { dir => 1 } )->each ],
        [], 'and no half-made backup is left' );
  };

subtest 'uploads tar cannot read are said, without a Perl warning' => sub {
    _unless_root();

    my $root   = $scratch->child('shut-uploads')->make_path;
    my $locked = $root->child('ab')->make_path;
    $locked->child('one')->spew('an upload');
    chmod $SHUT, "$locked" or croak "chmod: $OS_ERROR";

    my @warnings;
    local $SIG{__WARN__} = sub ($warning) { push @warnings, $warning };
    my $failure;
    try {
        _backup( 'en', GPFORUM_ATTACHMENT_ROOT => "$root" )
          ->take("$scratch/shut");
    }
    catch ($error) {
        $failure = "$error";
    };
    chmod $OPEN, "$locked" or croak "chmod: $OS_ERROR";

    my $start = "Cannot copy the uploads in $root (";
    my $end   = "): make every file and directory in it readable by $me,"
      . ' then run the backup again.';
    is( substr( $failure, 0, length $start ), $start, 'naming the uploads' );
    like( $failure, qr/Permission [ ] denied/msx, 'with what tar said' );
    is( substr( $failure, -length $end ), $end, 'and what to do' );
    is_deeply( \@warnings, [], 'and no Perl warning before it' );
};

subtest 'a path a shell would split is quoted in the command offered' => sub {
    my $run   = _run( 'en', 'GPForum::Command::Backup', '--to', 'my backups' );
    my $place = "$scratch/my backups/gpforum-20261009T055530Z";
    _has_line(
        $run->{output},
        q{Next: check that it can be restored, with gpforum restore --check '}
          . $place . q{'},
        'the check after a backup'
    );

    $run =
      _run( 'en', 'GPForum::Command::Restore', '--check',
        "$scratch/my backups" );
    _has_line(
        $run->{output},
        q{Next: check its newest backup, with gpforum restore --check '}
          . $place . q{'},
        'the newest backup offered'
    );

    is(
        GPForum::Service::Operations::Host->shell_word('/var/backups/gpforum'),
        '/var/backups/gpforum', 'a path a shell reads as it is stays so'
    );
    is(
        GPForum::Service::Operations::Host->shell_word(q{/srv/it's}),
        q{'/srv/it'\''s'},
        'a quote in one is quoted too'
    );

  SKIP: {
        if ( !$EFFECTIVE_USER_ID ) {
            skip 'root writes into any directory', 1;
        }
        my $locked = $scratch->child('locked dir')->make_path;
        chmod oct '500', "$locked" or croak "chmod: $OS_ERROR";
        $run =
          _run( 'en', 'GPForum::Command::Backup', '--to', "$locked/backups" );
        chmod $OPEN, "$locked" or croak "chmod: $OS_ERROR";
        my $make = "sudo install -d -o $me -m 700 '$locked/backups'\n";
        is( substr( $run->{errors}, -length $make ),
            $make, 'and the directory to make' );
    }
};

subtest 'under sudo -u, the check offered runs as the account that took it' =>
  sub {
    local $ENV{SUDO_USER} = 'someone-who-typed-sudo';
    my $run  = _run( 'en', 'GPForum::Command::Backup', '--to', 'as-sudo' );
    my $sudo = _sudo_as_me();
    _has_line(
        $run->{output},
        "Next: check that it can be restored, with $sudo gpforum restore"
          . " --check $scratch/as-sudo/gpforum-20261009T055530Z",
        'with sudo, as it was typed'
    );

    local $ENV{SUDO_USER} = $me;
    $run = _run( 'en', 'GPForum::Command::Backup', '--to', 'as-self' );
    _has_line(
        $run->{output},
        'Next: check that it can be restored, with gpforum restore --check'
          . " $scratch/as-self/gpforum-20261009T055530Z",
        'and without it when the account is the one that typed it'
    );
  };

done_testing;

# A fresh backup, in a directory of its own.
sub _taken {
    $count++;
    return _backup('en')->take("$scratch/backups-$count")->{directory};
}

# A backup's manifest changed by a sub.
sub _manifest ( $place, $change ) {
    my $file     = path( $place, 'manifest.json' );
    my $manifest = decode_json( $file->slurp );
    $change->($manifest);
    $file->spew( encode_json($manifest) );

    return;
}

# A pg_dump that says these lines on standard error and fails.
sub _client ( $name, @lines ) {
    my $script = $scratch->child($name);
    $script->spew( "#!/bin/sh\n"
          . q{case "$1" in --version) echo 'pg_dump (PostgreSQL) 16.4';}
          . qq{ exit 0;; esac\n}
          . join( q{}, map { "echo '$_' >&2\n" } @lines )
          . "exit 1\n" );
    $script->chmod( oct '755' );

    return "$script";
}

# What a backup taken with this pg_dump failed with.
sub _failure ( $language, $pg_dump, $into ) {
    my $backup = _backup($language);
    $backup->clients->pg_dump($pg_dump);
    my $said;
    try {
        $backup->take("$into");
    }
    catch ($error) {
        $said = "$error";
    };

    return $said;
}

# Whether a text has a line, whole.
sub _has_line ( $text, $line, $name ) {
    my $found = grep { $_ eq $line } split /\n/msx, $text;
    return ok( $found, $name ) || diag $text;
}

# The service with this test's settings and fake clients, in a language.
sub _backup ( $language, %settings ) {
    local $ENV{GPFORUM_DATABASE_DSN}    = 'dbi:Pg:dbname=forum;host=db.test';
    local $ENV{GPFORUM_ATTACHMENT_ROOT} = "$uploads";
    local @ENV{ keys %settings }        = values %settings;

    return GPForum::Service::Operations::Backup->new(
        config  => GPForum::Config->from_environment,
        clients => GPForum::Test::BackupClients->tools($clients),
        root    => "$code",
        catalog =>
          GPForum::Service::I18N::CliCatalog->new( language => $language ),
        clock    => sub { return $TAKEN },
        database => {
            name   => 'forum',
            host   => 'db.test',
            port   => q{},
            server => '18.6',
            schema => '051',
        },
    );
}

# A command run with this test's service, its output and errors kept.
sub _run ( $language, $class, @arguments ) {
    my $backup = _backup($language);
    my $words  = GPForum::Command::Support::Words->new(
        catalog => GPForum::Service::I18N::CliCatalog->new(
            language => $language
        )
    );
    my %handles = $class eq 'GPForum::Command::Backup' ? ( errors => 1 ) : ();

    return _captured(
        sub ( $out, $err ) {
            return $class->new(
                backup    => $backup,
                directory => "$scratch",
                words     => $words,
                output    => $out,
                ( $handles{errors} ? ( errors => $err ) : () ),
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

# The cases that shut a directory to this account mean nothing to root.
sub _unless_root {
    if ( !$EFFECTIVE_USER_ID ) {
        plan skip_all => 'root reads every directory';
    }

    return;
}

# How a check runs as this account, typed under sudo.
sub _sudo_as_me {
    return $me eq 'root' ? 'sudo' : "sudo -u $me";
}

1;
