# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use DBI;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::Config;
use GPForum::Migration::Plan;
use GPForum::Migration::Runner;
use GPForum::Schema;
use GPForum::Service::Operations::Backup;
use GPForum::Service::Operations::DatabaseProvisioning;
use GPForum::Service::Operations::StagingDrill::PgTools;

our $VERSION = '0.001';

const my $SERVER_VERSION_UNIT => 10_000;

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the backup on PostgreSQL';
}

# gpforum backup and restore --check on a real PostgreSQL: a migrated
# database of its own, with a row in it, is backed up with the host's
# pg_dump and tar; the check reads the dump with the host's pg_restore; and
# the dump, restored into a second database, holds the row. Both databases
# are dropped at the end.

my $source = GPForum::Service::Operations::DatabaseProvisioning->data_source(
    $ENV{GPFORUM_DATABASE_DSN} );
my $server = "host=$source->{host};port=$source->{port}";
my $admin  = DBI->connect(
    "dbi:Pg:dbname=postgres;$server",
    $ENV{GPFORUM_DATABASE_USER}     // q{},
    $ENV{GPFORUM_DATABASE_PASSWORD} // q{},
    { AutoCommit => 1, PrintError => 0, RaiseError => 1 }
);

my $tools;
try {
    $tools = GPForum::Service::Operations::StagingDrill::PgTools->find;
}
catch ($error) {
    plan skip_all => "no PostgreSQL client tools: $error";
};
my $major = int(
    $admin->selectrow_array('SHOW server_version_num') / $SERVER_VERSION_UNIT );
my ($client) = $tools->version_of('pg_dump') =~ /\A (\d+)/msx;
if ( $client < $major ) {
    plan skip_all => "pg_dump $client cannot dump a PostgreSQL $major server";
}

my $name     = "gpforum_t_backup_$PROCESS_ID";
my $restored = "${name}_restored";
my $scratch  = path( tempdir( CLEANUP => 1 ) );
my $uploads  = $scratch->child('uploads')->make_path;
my $nested   = $uploads->child('ab/cd')->make_path;
$nested->child('blob')->spew('an attachment');

for my $database ( $name, $restored ) {
    $admin->do("CREATE DATABASE $database");
}

try {
    local $ENV{GPFORUM_DATABASE_DSN}    = "dbi:Pg:dbname=$name;$server";
    local $ENV{GPFORUM_ATTACHMENT_ROOT} = "$uploads";
    local $ENV{GPFORUM_ENV}             = 'development';
    my $config = GPForum::Config->from_environment;
    my $schema = GPForum::Schema->connect_from_config($config);
    my $runner = GPForum::Migration::Runner->new( schema => $schema );
    $runner->apply_pending;
    $schema->storage->dbh->do(
        q{CREATE TABLE backup_probe (said text NOT NULL)});
    $schema->storage->dbh->do(
        q{INSERT INTO backup_probe (said) VALUES ('kept by the backup')});
    $schema->storage->disconnect;
    my $latest = GPForum::Migration::Plan->new->summary->[-1]{version};

    subtest 'gpforum backup takes the database and the uploads' => sub {
        my $backup = GPForum::Service::Operations::Backup->new(
            config => $config,
            root   => "$scratch/code",
        );
        my $taken    = $backup->take("$scratch/backups");
        my $manifest = $taken->{manifest};
        is( $manifest->{database}{name}, $name, 'the database the DSN names' );
        is( $manifest->{versions}{schema}, $latest, 'at the latest migration' );
        like(
            $manifest->{versions}{postgresql},
            qr/\A $major [.]/msx,
            q{the server's version}
        );
        is( $manifest->{attachments}{files}, 1, 'and the one upload' );

        my $check = $backup->check( $taken->{directory} );
        is( $check->{findings}->status, 'ok', 'restore --check finds it whole' )
          or diag explain $check->{findings}->document;

        $tools->restore_database(
            "dbi:Pg:dbname=$restored;$server",
            "$taken->{directory}/database.dump"
        );
        my $copy = DBI->connect(
            "dbi:Pg:dbname=$restored;$server",
            $ENV{GPFORUM_DATABASE_USER}     // q{},
            $ENV{GPFORUM_DATABASE_PASSWORD} // q{},
            { AutoCommit => 1, PrintError => 0, RaiseError => 1 }
        );
        is(
            scalar $copy->selectrow_array('SELECT said FROM backup_probe'),
            'kept by the backup',
            'and the dump restores the rows'
        );
        is(
            scalar $copy->selectrow_array(
                'SELECT max(version) FROM schema_versions'),
            $latest,
            'and the schema'
        );
        $copy->disconnect;
    };
}
catch ($error) {
    fail("the backup on PostgreSQL: $error");
};

for my $database ( $restored, $name ) {
    $admin->do("DROP DATABASE IF EXISTS $database WITH (FORCE)");
}
$admin->disconnect;

done_testing;

1;
