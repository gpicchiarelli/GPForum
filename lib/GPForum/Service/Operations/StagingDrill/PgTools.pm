# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::StagingDrill::PgTools;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use GPForum::X::Config;
use GPForum::X::Unavailable;
use IPC::Open3 qw(open3);
use List::Util qw(first);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File qw(path);
use POSIX      qw(WIFEXITED WEXITSTATUS);
use Symbol     qw(gensym);

our $VERSION = '0.001';

# Where a client is looked for after GPFORUM_PG_DUMP / GPFORUM_PG_RESTORE and
# PATH: the Debian and Ubuntu packages, newest first, the usual prefixes,
# Homebrew's postgresql@18 (keg-only, so not on PATH) and libpq, and
# Postgres.app. pg_dump refuses a server newer than itself.
const my @TOOL_DIRECTORIES => qw(
  /usr/lib/postgresql/18/bin
  /usr/lib/postgresql/17/bin
  /usr/lib/postgresql/16/bin
  /usr/lib/postgresql/15/bin
  /usr/lib/postgresql/14/bin
  /usr/bin
  /usr/local/bin
  /opt/homebrew/opt/postgresql@18/bin
  /usr/local/opt/postgresql@18/bin
  /opt/homebrew/opt/libpq/bin
  /usr/local/opt/libpq/bin
  /Applications/Postgres.app/Contents/Versions/latest/bin
);
const my $DBNAME         => qr/dbname=[^;]+/msx;
const my $VERSION_NUMBER => qr/([[:digit:]]+ (?: [.][[:digit:]]+ )*)/msxa;

has 'pg_dump';       # optional: found by find
has 'pg_restore';    # optional: found by find

# The role and password to connect as, when the caller has them from the
# settings; GPFORUM_DATABASE_USER and GPFORUM_DATABASE_PASSWORD otherwise.
has 'user';        # optional
has 'password';    # optional

sub find ($class) {
    my $pg_dump = _find_tool('pg_dump');
    if ( !_has_text($pg_dump) ) {
        GPForum::X::Config->throw(
            message => 'pg_dump not found on PATH (set GPFORUM_PG_DUMP)' );
    }
    my $pg_restore = _find_tool('pg_restore');
    if ( !_has_text($pg_restore) ) {
        GPForum::X::Config->throw( message =>
              'pg_restore not found on PATH (set GPFORUM_PG_RESTORE)' );
    }

    return $class->new( pg_dump => $pg_dump, pg_restore => $pg_restore );
}

sub dump_database ( $self, $dsn, $dump_path ) {
    my $parts = $self->parse_dsn($dsn);
    _run(
        [
            $self->pg_dump,      '--format=custom',
            "--file=$dump_path", _connection_args($parts),
            $parts->{dbname},
        ],
        $parts->{password}
    );

    return;
}

sub restore_database ( $self, $dsn, $dump_path ) {
    my $parts = $self->parse_dsn($dsn);
    _run(
        [
            $self->pg_restore,        '--no-owner',
            '--no-acl',               "--dbname=$parts->{dbname}",
            _connection_args($parts), $dump_path,
        ],
        $parts->{password}
    );

    return;
}

# What pg_restore reads of a dump, without restoring it: the archive's
# header and its table of contents, one entry a line.
sub list_dump ( $self, $dump_path ) {
    return _capture( [ $self->pg_restore, '--list', $dump_path ] );
}

# A client's version, such as 18.6, as its --version says it.
sub version_of ( $self, $tool ) {
    my $output = _capture( [ $self->$tool, '--version' ] );
    my ($version) = $output =~ $VERSION_NUMBER;

    return $version;
}

sub parse_dsn ( $self, $dsn ) {
    my %login =
      ref $self ? ( user => $self->user, password => $self->password ) : ();
    my %parts = (
        dbname   => undef,
        host     => undef,
        port     => undef,
        user     => $login{user}     // $ENV{GPFORUM_DATABASE_USER},
        password => $login{password} // $ENV{GPFORUM_DATABASE_PASSWORD},
    );
    for my $key (qw(dbname host port)) {
        if ( $dsn =~ /$key=([^;]+)/msx ) {
            $parts{$key} = $1;
        }
    }
    if ( !_has_text( $parts{dbname} ) ) {
        GPForum::X::Config->throw( message => 'DSN is missing dbname=' );
    }

    return \%parts;
}

sub rewrite_dsn ( $, $dsn, $dbname ) {
    if ( $dsn !~ $DBNAME ) {
        GPForum::X::Config->throw( message =>
              'GPFORUM_DATABASE_DSN must name a database with dbname=' );
    }

    return $dsn =~ s/$DBNAME/dbname=$dbname/msxr;
}

# GPFORUM_PG_DUMP or GPFORUM_PG_RESTORE when it names an executable, then the
# first executable on PATH, then the first in @TOOL_DIRECTORIES.
sub _find_tool ($name) {
    my $configured = $ENV{ 'GPFORUM_' . uc $name };

    return first { -x } (
        ( _has_text($configured) ? $configured : () ),
        (
            map { path( $_, $name )->to_string } split /:/msx,
            $ENV{PATH} // q{}
        ),
        ( map { "$_/$name" } @TOOL_DIRECTORIES ),
    );
}

sub _connection_args ($parts) {
    my %flag = ( host => '--host', port => '--port', user => '--username' );

    return map { "$flag{$_}=$parts->{$_}" }
      grep { _has_text( $parts->{$_} ) } qw(host port user);
}

# The password goes to the client through PGPASSWORD, set only for the
# command, and only when there is one.
sub _run ( $command, $password ) {
    if ( defined $password ) {
        local $ENV{PGPASSWORD} = $password;
        return _capture($command);
    }

    return _capture($command);
}

sub _capture ($command) {
    my $stderr = gensym;
    my $pid    = open3( my $stdin, my $stdout, $stderr, @{$command} );
    close $stdin or croak 'failed to close pg command stdin';
    my $output = q{};
    for my $handle ( $stdout, $stderr ) {
        while ( my $line = <$handle> ) {
            $output .= $line;
        }
        close $handle or croak 'failed to close pg command handle';
    }
    waitpid $pid, 0;
    if ( !WIFEXITED($CHILD_ERROR) || WEXITSTATUS($CHILD_ERROR) != 0 ) {
        GPForum::X::Unavailable->throw( message => 'pg command failed: '
              . join( q{ }, @{$command} ) . "\n"
              . ( $output =~ s/\s+\z//msxr ) );
    }

    return $output;
}

sub _has_text ($value) {
    return defined $value && length $value;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::StagingDrill::PgTools - The staging drill's
pg_dump and pg_restore.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $tools = GPForum::Service::Operations::StagingDrill::PgTools->find;
    $tools->dump_database( $source_dsn, $dump_path );
    $tools->restore_database( $target_dsn, $dump_path );

    my $parts = $tools->parse_dsn('dbi:Pg:dbname=gpforum;host=127.0.0.1');

=head1 DESCRIPTION

The PostgreSQL client side of L<GPForum::Service::Operations::StagingDrill>:
finding C<pg_dump> and C<pg_restore>, running them against a database named
by a DBI DSN, and reading and rewriting such a DSN.

=head1 SUBROUTINES/METHODS

=head2 find

Returns the tools, each found as C<GPFORUM_PG_DUMP> or C<GPFORUM_PG_RESTORE>
when that names an executable, else the first executable on C<PATH>, else the
first in a list of usual directories (the Debian and Ubuntu packages,
F</usr/bin>, F</usr/local/bin>, Homebrew's postgresql@18 and libpq,
Postgres.app).

=head2 dump_database

Takes a DSN and a path, and writes a custom-format dump of the DSN's database
there.

=head2 restore_database

Takes a DSN and a dump path, and restores the dump into the DSN's database,
without owners or privileges.

=head2 list_dump

Takes a dump's path and returns what C<pg_restore --list> reads of it: the
archive's header and its table of contents. It restores nothing.

=head2 version_of

Takes C<pg_dump> or C<pg_restore> and returns that client's version, such as
C<18.6>.

=head2 parse_dsn

Returns C<dbname>, C<host> and C<port> from a DBI DSN, with C<user> and
C<password> from the tools' own L</user> and L</password> when they were
given, else from C<GPFORUM_DATABASE_USER> and C<GPFORUM_DATABASE_PASSWORD>.

=head2 user

The role to connect as, optional.

=head2 password

That role's password, optional.

=head2 rewrite_dsn

Returns the DSN with its C<dbname=> set to another database.

=head1 DIAGNOSTICS

L</find> throws L<GPForum::X::Config> when a tool is not found;
L</parse_dsn> and L</rewrite_dsn> when the DSN names no database. A client
that exits non-zero throws L<GPForum::X::Unavailable> with the command and
its output.

=head1 CONFIGURATION AND ENVIRONMENT

C<GPFORUM_PG_DUMP>, C<GPFORUM_PG_RESTORE>, C<PATH>,
C<GPFORUM_DATABASE_USER> and C<GPFORUM_DATABASE_PASSWORD>. The password
reaches the client as C<PGPASSWORD>, for that command only.

=head1 DEPENDENCIES

L<IPC::Open3>, L<Mojo::File>, L<GPForum::X::Config>,
L<GPForum::X::Unavailable>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The DSN is read with patterns, not DBI's parser: a C<host=> inside another
key's value would be taken for the host.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
