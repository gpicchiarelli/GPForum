# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::PgDatabase;

use strict;
use warnings;

use Carp qw(carp croak);
use Const::Fast;
use Digest::SHA;
use English qw(-no_match_vars);
use File::Spec;

use GPForum::Command::Migrate;
use GPForum::Config;
use GPForum::Schema;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $MIGRATIONS    => 'migrations';
const my $NAME_DIGITS   => 12;
const my $SHA_BITS      => 256;
const my $TEMPLATE_LOCK => 2_026_092_601;

# A test's own PostgreSQL database, cloned from a template that holds the
# migrated schema, and the seed when asked for. The template is built once
# per migration set, by whichever test gets there first, under an advisory
# lock, so `prove -j` workers share it; a clone costs a CREATE DATABASE,
# where migrating and seeding cost a second.
#
# This is what lets a test run against PostgreSQL instead of a double of the
# ORM: the doubles reimplemented SQL's semantics, and each infidelity hid a
# defect (quality program 5.1).
sub fresh {
    my ( $class, %options ) = @_;

    my $admin_dsn = $class->admin_dsn;
    my $admin     = GPForum::Test::PostgresHarness::connect_dbi($admin_dsn);
    my $template  = $class->_template( $admin, $admin_dsn, $options{seed} );
    my $name      = sprintf 'gpforum_t_%d_%d', $PROCESS_ID, _serial();
    $admin->do(
        sprintf 'CREATE DATABASE %s TEMPLATE %s',
        $admin->quote_identifier($name),
        $admin->quote_identifier($template)
    );

    ( my $dsn = $admin_dsn ) =~ s/dbname=[^;]+/dbname=$name/msx;

    return bless {
        admin => $admin,
        dsn   => $dsn,
        name  => $name,
        owner => $PROCESS_ID,
    }, $class;
}

# The database the tests start from: GPFORUM_TEST_DSN, else
# GPFORUM_DATABASE_DSN. Undefined when neither is set, and the test skips.
sub admin_dsn {
    return $ENV{GPFORUM_TEST_DSN} // $ENV{GPFORUM_DATABASE_DSN};
}

sub dsn {
    my ($self) = @_;

    return $self->{dsn};
}

sub name {
    my ($self) = @_;

    return $self->{name};
}

sub schema {
    my ($self) = @_;

    if ( !$self->{schema} ) {
        local $ENV{GPFORUM_DATABASE_DSN} = $self->{dsn};
        $self->{schema} = GPForum::Schema->connect_from_config(
            GPForum::Config->from_environment );
    }

    return $self->{schema};
}

sub dbh {
    my ($self) = @_;

    return $self->schema->storage->dbh;
}

sub DESTROY {
    my ($self) = @_;

    return if !$self->{admin} || $self->{owner} != $PROCESS_ID;
    if ( $self->{schema} ) {
        $self->{schema}->storage->disconnect;
    }
    local $EVAL_ERROR = undef;
    eval {
        $self->{admin}->do( 'DROP DATABASE IF EXISTS '
              . $self->{admin}->quote_identifier( $self->{name} )
              . ' WITH (FORCE)' );
        $self->{admin}->disconnect;
        1;
    } or carp "could not drop $self->{name}: $EVAL_ERROR";

    return;
}

sub _template {
    my ( $class, $admin, $admin_dsn, $seed ) = @_;

    my $name = sprintf 'gpforum_tpl_%s_%s', ( $seed ? 'seed' : 'bare' ),
      substr _migration_digest(), 0, $NAME_DIGITS;

    # A session lock: CREATE DATABASE cannot run in a transaction.
    $admin->do( 'SELECT pg_advisory_lock(?)', undef, $TEMPLATE_LOCK );
    my $ready = eval {
        if ( !_exists( $admin, $name ) ) {
            _build( $admin, $admin_dsn, $name, $seed );
        }
        1;
    };
    my $error = $EVAL_ERROR;
    $admin->do( 'SELECT pg_advisory_unlock(?)', undef, $TEMPLATE_LOCK );
    croak $error if !$ready;

    return $name;
}

sub _build {
    my ( $admin, $admin_dsn, $name, $seed ) = @_;

    my $building = "${name}_building";
    $admin->do( 'DROP DATABASE IF EXISTS '
          . $admin->quote_identifier($building)
          . ' WITH (FORCE)' );
    $admin->do( 'CREATE DATABASE ' . $admin->quote_identifier($building) );
    ( my $dsn = $admin_dsn ) =~ s/dbname=[^;]+/dbname=$building/msx;
    {
        local $ENV{GPFORUM_DATABASE_DSN} = $dsn;
        my $prepared =
          $seed
          ? GPForum::Test::PostgresHarness::prepare_database()
          : {
            migrate => GPForum::Test::PostgresHarness::quietly(
                sub { GPForum::Command::Migrate->new->run('--apply') }
            ),
            seed => 0,
          };
        croak "template $name: migrate $prepared->{migrate},"
          . " seed $prepared->{seed}"
          if $prepared->{migrate} || $prepared->{seed};
    }

    # Renamed only once complete, so a test never clones a half-built one;
    # the build's own connections have to go first.
    $admin->do(
        q{SELECT pg_terminate_backend(pid) FROM pg_stat_activity}
          . q{ WHERE datname = ? AND pid <> pg_backend_pid()},
        undef, $building
    );
    $admin->do(
        sprintf 'ALTER DATABASE %s RENAME TO %s',
        $admin->quote_identifier($building),
        $admin->quote_identifier($name)
    );

    return;
}

sub _exists {
    my ( $admin, $name ) = @_;

    return
      scalar $admin->selectrow_array(
        'SELECT count(*) FROM pg_database WHERE datname = ?',
        undef, $name );
}

# The template is rebuilt when a migration changes.
sub _migration_digest {
    opendir my $directory, $MIGRATIONS
      or croak "cannot read $MIGRATIONS: $OS_ERROR";
    my @files = sort grep { /[.]sql\z/msx } readdir $directory;
    closedir $directory or croak "cannot close $MIGRATIONS: $OS_ERROR";

    my $digest = Digest::SHA->new($SHA_BITS);
    for my $file (@files) {
        $digest->add($file);
        $digest->addfile( File::Spec->catfile( $MIGRATIONS, $file ) );
    }

    return $digest->hexdigest;
}

{
    my $serial = 0;

    sub _serial {
        return ++$serial;
    }
}

1;

__END__

=head1 NAME

GPForum::Test::PgDatabase - A fresh PostgreSQL database per test, cloned from a migrated template.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use GPForum::Test::PgDatabase;

    plan skip_all => 'set GPFORUM_TEST_DSN to run against PostgreSQL'
      if !GPForum::Test::PgDatabase->admin_dsn;

    my $database = GPForum::Test::PgDatabase->fresh( seed => 1 );
    my $schema   = $database->schema;

=head1 DESCRIPTION

Clones a database from a template holding the migrated schema (and the small
seed, with C<< seed => 1 >>). The template is built once per set of
migrations and shared by every test and C<prove -j> worker; the clone is
dropped when the object goes out of scope.

=head1 SUBROUTINES/METHODS

=head2 fresh

Creates and returns a new database. C<< seed => 1 >> clones the seeded
template.

=head2 admin_dsn

C<GPFORUM_TEST_DSN>, else C<GPFORUM_DATABASE_DSN>; undefined when neither is
set.

=head2 dsn

The clone's DSN.

=head2 name

The clone's database name.

=head2 schema

A L<GPForum::Schema> connected to the clone.

=head2 dbh

The schema's DBI handle.

=head1 DIAGNOSTICS

Dies when the template cannot be built or the clone created.

=head1 CONFIGURATION AND ENVIRONMENT

C<GPFORUM_TEST_DSN> or C<GPFORUM_DATABASE_DSN>, naming a database the user
may create databases from; C<GPFORUM_DATABASE_USER> and
C<GPFORUM_DATABASE_PASSWORD>.

=head1 DEPENDENCIES

L<GPForum::Test::PostgresHarness>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Templates of earlier migration sets are left behind; drop
C<gpforum_tpl_*> databases to reclaim them.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
