# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Migration::Plan;
use GPForum::Service::Operations::StagingDrill;
use GPForum::Service::Operations::StagingDrill::PgTools;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $SERVER_VERSION_UNIT => 10_000;
const my $SEED_VERSION        => '999_staging_drill_seed';
const my $PREVIOUS_MIGRATION  => -2;
const my $SKIPPED_UPGRADE_LINE =>
  'upgrade_path status=skipped reason=operator passed --skip-upgrade';

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the staging drill';
}

# pg_dump refuses a server newer than itself, so the drill can only be run
# where the client is at least the server's major version.
my $admin =
  GPForum::Test::PostgresHarness::connect_dbi( $ENV{GPFORUM_DATABASE_DSN} );
my $tools;
try {
    $tools = GPForum::Service::Operations::StagingDrill::PgTools->find;
}
catch ($error) {
    plan skip_all => "no PostgreSQL client tools: $error";
};
my $server = int(
    $admin->selectrow_array('SHOW server_version_num') / $SERVER_VERSION_UNIT );
my $client = _client_major( $tools->pg_dump );
if ( $client < $server ) {
    plan skip_all => "pg_dump $client cannot dump a PostgreSQL $server server";
}

# The whole drill against the server: a fresh database migrated twice, one
# migrated to the version before the latest and then upgraded, and the fresh
# one seeded, dumped and restored into a third. Every throwaway database is
# dropped afterwards, newest first.
my $plan       = GPForum::Migration::Plan->new->summary;
my $migrations = scalar @{$plan};
my $prefix     = "gpforum_t_drill_$PROCESS_ID";
my @seeded;
my $drill = GPForum::Service::Operations::StagingDrill->new(
    seed => sub ($profile) {
        push @seeded, [ $profile, $ENV{GPFORUM_DATABASE_DSN} ];
        my $dbh = GPForum::Test::PostgresHarness::connect_dbi(
            $ENV{GPFORUM_DATABASE_DSN} );
        $dbh->do(
            'INSERT INTO schema_versions (version, description, checksum)'
              . q{ VALUES (?, 'seeded by the drill test', 'none')},
            undef, $SEED_VERSION
        );
        $dbh->disconnect;
        print "seeding output the drill keeps quiet\n"
          or croak 'cannot print';

        return 0;
    },
);
my $evidence =
  $drill->run( { seed_profile => 'small', database_prefix => $prefix } );

is( $evidence->{status}, 'pass', 'the drill passes' )
  or diag( $evidence->{error} // 'no error' );
is_deeply(
    $evidence->{fresh_migrate},
    {
        status              => 'pass',
        database            => "${prefix}_fresh",
        schema_versions     => $migrations,
        expected_migrations => $migrations,
        second_apply_delta  => 0,
    },
    'migrating twice leaves every migration recorded once'
);
is_deeply(
    $evidence->{upgrade_path},
    {
        status                 => 'pass',
        database               => "${prefix}_upgrade",
        from_version           => $plan->[$PREVIOUS_MIGRATION]{version},
        to_version             => $plan->[-1]{version},
        schema_versions_before => $migrations - 1,
        schema_versions_after  => $migrations,
        expected_migrations    => $migrations,
    },
    'the upgrade runs the last migration on the one before'
);
is_deeply(
    \@seeded,
    [
        [
            'small',
            $drill->rewrite_dsn(
                $ENV{GPFORUM_DATABASE_DSN}, "${prefix}_fresh"
            )
        ]
    ],
    'the seed runs once, with its profile, on the fresh database'
);
is_deeply(
    $evidence->{dump_restore},
    {
        status           => 'pass',
        source_database  => "${prefix}_fresh",
        restore_database => "${prefix}_restore",
        schema_versions  => $migrations + 1,
        users            => 0,
        threads          => 0,
    },
    'the restored copy counts the seeded rows'
);
is_deeply(
    $evidence->{databases_dropped},
    [ map { "${prefix}_$_" } qw(restore upgrade fresh) ],
    'and every database is dropped, newest first'
);
is( _databases($prefix), 0,     'none is left on the server' );
is( $evidence->{_fresh}, undef, 'the evidence keeps no handle' );
is(
    $drill->format_evidence( $evidence, 'human' ),
    join( "\n",
        'staging-drill status=pass',
        "fresh_migrate status=pass schema_versions=$migrations",
        "upgrade_path status=pass schema_versions_after=$migrations",
        'dump_restore status=pass schema_versions='
          . ( $migrations + 1 )
          . ' users=0 threads=0',
        'attachments covered=false root=var/attachments' )
      . "\n",
    'the human text gives each phase its counts'
);

# Skipped phases do not fail the drill, and a kept database stays.
my $kept = GPForum::Service::Operations::StagingDrill->new->run(
    {
        seed_profile      => 'none',
        database_prefix   => "${prefix}_kept",
        skip_upgrade      => 1,
        skip_dump_restore => 1,
        keep_databases    => 1,
    }
);
is( $kept->{status}, 'pass', 'a drill with the optional phases skipped passes' )
  or diag( $kept->{error} // 'no error' );
is_deeply( $kept->{databases_dropped}, [], 'keeping its database' );
is( _databases("${prefix}_kept"), 1, 'which is still on the server' );
like(
    GPForum::Service::Operations::StagingDrill->new->format_evidence(
        $kept, 'human'
    ),
    qr/^\Q$SKIPPED_UPGRADE_LINE\E$/msx,
    'the human text says why a phase was skipped'
);
$admin->do("DROP DATABASE ${prefix}_kept_fresh WITH (FORCE)");

# A seed that fails fails the drill before the dump; the databases made so
# far are dropped all the same.
my $refused = GPForum::Service::Operations::StagingDrill->new(
    seed => sub ($profile) { return 1 } );
my $failed = $refused->run(
    { seed_profile => 'small', database_prefix => "${prefix}_failed" } );
is( $failed->{status}, 'fail', 'a failing seed fails the drill' );
is( $failed->{error},  'seed profile small failed', 'naming the profile' );
is( $failed->{fresh_migrate}{status}, 'pass', 'after the fresh phase passed' );
is( $failed->{dump_restore},          undef,  'and before any dump' );
is_deeply(
    $failed->{databases_dropped},
    [ map { "${prefix}_failed_$_" } qw(upgrade fresh) ],
    'the databases it made are dropped'
);
is( $refused->exit_status($failed), 1, 'and it exits 1' );
like(
    $refused->format_evidence( $failed, 'human' ),
    qr/^dump_restore [ ] status=missing $ .* ^error=seed [ ] profile/msx,
    'the human text shows the phase that did not run and the error'
);

# A restore that comes back short fails the drill: a pg_dump that leaves out
# schema_versions' rows stands in for one.
my $short_dump = path( tempdir( CLEANUP => 1 ) )->child('pg_dump');
$short_dump->spew( sprintf "#!/bin/sh\nexec '%s' %s \"\$\@\"\n",
    $tools->pg_dump, '--exclude-table-data=schema_versions' );
$short_dump->chmod( oct '0755' );
{
    local $ENV{GPFORUM_PG_DUMP}    = $short_dump->to_string;
    local $ENV{GPFORUM_PG_RESTORE} = $tools->pg_restore;
    my $short = GPForum::Service::Operations::StagingDrill->new->run(
        {
            seed_profile    => 'none',
            database_prefix => "${prefix}_short",
            skip_upgrade    => 1,
        }
    );
    is( $short->{status}, 'fail', 'a restore missing rows fails the drill' );
    is(
        $short->{error},
        "restore mismatch on schema_versions: $migrations vs 0",
        'naming the table and both counts'
    );
    is_deeply(
        $short->{databases_dropped},
        [ map { "${prefix}_short_$_" } qw(restore fresh) ],
        'and still drops both databases'
    );
}
is( _databases($prefix), 0, 'nothing the drills made is left' );

$admin->disconnect;
done_testing();

sub _client_major ($pg_dump) {
    open my $output, q{-|}, $pg_dump, '--version'
      or croak "cannot run $pg_dump: $OS_ERROR";
    my $version = do { local $INPUT_RECORD_SEPARATOR = undef; <$output> };
    close $output or croak "cannot close $pg_dump: $OS_ERROR";
    my ($major) = $version =~ /([[:digit:]]+)/msxa;

    return $major;
}

sub _databases ($name_prefix) {
    return
      scalar $admin->selectrow_array(
        q{SELECT count(*) FROM pg_database WHERE datname LIKE ? || '%'},
        undef, $name_prefix );
}

1;
