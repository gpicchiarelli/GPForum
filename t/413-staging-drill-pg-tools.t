# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use File::Temp  qw(tempdir);
use Mojo::File  qw(path);
use Test::Fatal qw(exception);
use Test::More;

use lib 'lib';

use GPForum::Service::Operations::StagingDrill;
use GPForum::Service::Operations::StagingDrill::PgTools;
use GPForum::X::Config;
use GPForum::X::Unavailable;

our $VERSION = '0.001';

# These client fixtures supply their own credentials and executables. A CI
# database configuration must not become part of their arguments or output.
delete local $ENV{GPFORUM_DATABASE_USER};
delete local $ENV{GPFORUM_DATABASE_PASSWORD};
delete local $ENV{GPFORUM_PG_DUMP};
delete local $ENV{GPFORUM_PG_RESTORE};
delete local $ENV{PGPASSWORD};

const my $PG_TOOLS => 'GPForum::Service::Operations::StagingDrill::PgTools';

# Where PgTools looks after GPFORUM_PG_* and PATH; a host that has a client
# there cannot show the refusal for a missing one.
const my @PACKAGED_DIRECTORIES => qw(
  /usr/lib/postgresql/18/bin /usr/lib/postgresql/17/bin
  /usr/lib/postgresql/16/bin /usr/lib/postgresql/15/bin
  /usr/lib/postgresql/14/bin /usr/bin /usr/local/bin
  /opt/homebrew/opt/postgresql@18/bin /usr/local/opt/postgresql@18/bin
  /opt/homebrew/opt/libpq/bin /usr/local/opt/libpq/bin
  /Applications/Postgres.app/Contents/Versions/latest/bin
);

# The staging drill finds pg_dump and pg_restore (GPFORUM_PG_DUMP and
# GPFORUM_PG_RESTORE first, then PATH, then the packaged locations) and runs
# them on a DSN's parts, the password passed in PGPASSWORD for that command
# only. Fake clients keep the arguments and the password they were given.
my $log       = path( tempdir( CLEANUP => 1 ) );
my $clients   = _clients( $log, 'pg_dump', 'pg_restore' );
my $elsewhere = _clients( $log, 'pg_dump', 'pg_restore' );
my $empty     = tempdir( CLEANUP => 1 );

{
    local $ENV{GPFORUM_PG_DUMP}    = "$clients/pg_dump";
    local $ENV{GPFORUM_PG_RESTORE} = "$clients/pg_restore";
    local $ENV{PATH}               = $elsewhere;
    my $tools = $PG_TOOLS->find;
    is( $tools->pg_dump,    "$clients/pg_dump",    'GPFORUM_PG_DUMP wins' );
    is( $tools->pg_restore, "$clients/pg_restore", 'GPFORUM_PG_RESTORE wins' );
}
{
    local $ENV{GPFORUM_PG_DUMP} = "$empty/pg_dump";
    delete local $ENV{GPFORUM_PG_RESTORE};
    local $ENV{PATH} = "$empty:$elsewhere";
    my $tools = $PG_TOOLS->find;
    is( $tools->pg_dump, "$elsewhere/pg_dump",
        'a GPFORUM_PG_DUMP that is not executable gives way to PATH' );
    is( $tools->pg_restore, "$elsewhere/pg_restore",
        'the first executable on PATH is taken' );
}
SKIP: {
    my @packaged = grep { -x "$_/pg_restore" } @PACKAGED_DIRECTORIES;
    if (@packaged) {
        skip 'a packaged pg_restore is installed', 2;
    }

    local $ENV{GPFORUM_PG_DUMP} = "$clients/pg_dump";
    delete local $ENV{GPFORUM_PG_RESTORE};
    local $ENV{PATH} = $empty;
    my $error = exception { $PG_TOOLS->find };
    ok( GPForum::X::Config->caught($error),
        'a missing client is a configuration problem' );
    is(
        "$error",
        'pg_restore not found on PATH (set GPFORUM_PG_RESTORE)',
        'naming the variable that points at it'
    );
}

my $tools = $PG_TOOLS->new(
    pg_dump    => "$clients/pg_dump",
    pg_restore => "$clients/pg_restore"
);
my $dump = $log->child('drill.dump')->to_string;
{
    local $ENV{GPFORUM_DATABASE_USER}     = 'drill';
    local $ENV{GPFORUM_DATABASE_PASSWORD} = 'drill-password';
    delete local $ENV{PGPASSWORD};
    $tools->dump_database( 'dbi:Pg:dbname=source;host=db.test;port=6543',
        $dump );
    is_deeply(
        _arguments('pg_dump'),
        [
            '--format=custom',  "--file=$dump",
            '--host=db.test',   '--port=6543',
            '--username=drill', 'source',
        ],
        'pg_dump writes a custom-format dump of the source database'
    );
    is( _password('pg_dump'), 'drill-password', 'given the password' );
    is( $ENV{PGPASSWORD},     undef, 'which is not left in the environment' );

    $tools->restore_database( 'dbi:Pg:dbname=target;host=db.test', $dump );
    is_deeply(
        _arguments('pg_restore'),
        [
            '--no-owner',       '--no-acl',
            '--dbname=target',  '--host=db.test',
            '--username=drill', $dump,
        ],
        'pg_restore loads it into the target, without owners or grants'
    );
}
{
    delete local $ENV{GPFORUM_DATABASE_USER};
    delete local $ENV{GPFORUM_DATABASE_PASSWORD};
    delete local $ENV{PGPASSWORD};
    $tools->dump_database( 'dbi:Pg:dbname=source', $dump );
    is_deeply(
        _arguments('pg_dump'),
        [ '--format=custom', "--file=$dump", 'source' ],
        'a DSN with only a database passes only the database'
    );
    is( _password('pg_dump'), '(unset)', 'and no password' );
}

my $failing = path( tempdir( CLEANUP => 1 ) )->child('pg_dump');
$failing->spew("#!/bin/sh\necho partial\necho boom >&2\nexit 3\n");
$failing->chmod( oct '0755' );
my $error = exception {
    $PG_TOOLS->new( pg_dump => "$failing" )
      ->dump_database( 'dbi:Pg:dbname=source', $dump );
};
ok( GPForum::X::Unavailable->caught($error),
    'a client that exits non-zero is an unavailable dependency' );
is(
    "$error",
    "pg command failed: $failing --format=custom --file=$dump source\n"
      . "partial\nboom",
    'naming the command, then what it printed to stdout and stderr'
);

# Without a database environment the drill fails before it touches a server,
# and still reports what it is and what it does not cover.
for my $case (
    [ undef, 'GPFORUM_DATABASE_DSN is required' ],
    [
        'dbi:Pg:host=127.0.0.1',
        'GPFORUM_DATABASE_DSN must name a database with dbname='
    ],
  )
{
    my ( $dsn, $message ) = @{$case};
    local $ENV{GPFORUM_DATABASE_DSN} = $dsn;
    my $drill    = GPForum::Service::Operations::StagingDrill->new;
    my $evidence = $drill->run( { seed_profile => 'none' } );
    is( $evidence->{status}, 'fail',   "$message: the drill fails" );
    is( $evidence->{error},  $message, 'saying why' );
    is_deeply( $evidence->{databases_dropped}, [], 'having created nothing' );
    is( $drill->exit_status($evidence), 1, 'and exits 1' );
}

delete local $ENV{GPFORUM_DATABASE_DSN};
my $evidence = GPForum::Service::Operations::StagingDrill->new->run(
    { seed_profile => q{none} } );
is_deeply(
    [
        $evidence->{check},
        ${ $evidence->{attachments}{covered} },
        $evidence->{attachments}{storage_root},
    ],
    [ 'staging_drill', 0, 'var/attachments' ],
    'the evidence says attachments under var/attachments are not covered'
);
is( $evidence->{_fresh}, undef, 'and keeps no handle' );

# The clients are looked for before any database is made, and only when the
# dump and restore phase is to run.
SKIP: {
    my @packaged = grep { -x "$_/pg_dump" } @PACKAGED_DIRECTORIES;
    if (@packaged) {
        skip 'a packaged pg_dump is installed', 2;
    }

    local $ENV{GPFORUM_DATABASE_DSN} =
      'dbi:Pg:dbname=nowhere;host=127.0.0.1;port=1';
    delete local $ENV{GPFORUM_PG_DUMP};
    local $ENV{PATH} = $empty;
    my $drill = GPForum::Service::Operations::StagingDrill->new;
    is(
        $drill->run( { seed_profile => 'none' } )->{error},
        'pg_dump not found on PATH (set GPFORUM_PG_DUMP)',
        'a drill that would dump needs pg_dump before anything else'
    );
    unlike(
        $drill->run( { seed_profile => 'none', skip_dump_restore => 1 } )
          ->{error},
        qr/not [ ] found [ ] on [ ] PATH/msx,
        'one that skips the dump does not look for it'
    );
}

done_testing();

sub _clients ( $directory, @names ) {
    my $bin = path( tempdir( CLEANUP => 1 ) );
    for my $name (@names) {
        my $client = $bin->child($name);
        $client->spew(<<~"SH");
            #!/bin/sh
            printf '%s\\n' "\$@" > "$directory/$name.args"
            printf '%s' "\${PGPASSWORD-(unset)}" > "$directory/$name.password"
            SH
        $client->chmod( oct '0755' );
    }

    return $bin->to_string;
}

sub _arguments ($name) {
    return [ split /\n/msx, $log->child("$name.args")->slurp ];
}

sub _password ($name) {
    return $log->child("$name.password")->slurp;
}

1;
