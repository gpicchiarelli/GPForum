# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::DatabaseFailure;

use Const::Fast;
use List::Util qw(any);
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::OS;
use GPForum::Service::I18N::CliCatalog;

our $VERSION = '0.001';

# What an operator reads when a command cannot use the database, in English,
# keyed as the command-line catalogs (locale/cli/*.po) key their messages;
# it.po has the Italian, and t/473 holds en.po to these words. One sentence
# each: what is wrong, where to correct it and the command that fixes it. The
# walkthrough found every command printing DBIx::Class's own text instead,
# which names neither the variable nor the file nor what to run.
const my %ENGLISH => (
    'database.refused' => 'Cannot reach PostgreSQL at {server}'
      . ' (connection refused): start it with {start},'
      . ' or correct GPFORUM_DATABASE_DSN {where}.',
    'database.unknown_host' => 'Cannot find the PostgreSQL host {host}:'
      . ' correct the host in GPFORUM_DATABASE_DSN {where}.',
    'database.authentication' => 'PostgreSQL at {server} refused the'
      . ' password of role {user}: correct GPFORUM_DATABASE_PASSWORD'
      . q{ {where}, or set the role's password with {set_password}.},
    'database.no_hba' => 'PostgreSQL at {server} does not let role {user}'
      . ' connect to {database} from this host: allow it in pg_hba.conf,'
      . ' or correct GPFORUM_DATABASE_DSN {where}.',
    'database.unknown_role' => 'PostgreSQL at {server} has no role {user}:'
      . ' create it with {create_role},'
      . ' or correct GPFORUM_DATABASE_USER {where}.',
    'database.unknown_database' => 'PostgreSQL at {server} has no database'
      . ' {database}: create it with {create_database},'
      . ' or correct GPFORUM_DATABASE_DSN {where}.',
    'database.not_migrated' => 'The database has no {relation} table yet:'
      . ' apply the migrations with {migrate},'
      . ' or check that GPFORUM_DATABASE_DSN {where} names the'
      . q{ forum's database.},
    'database.unread_file' => 'This command did not read {path}, which holds'
      . q{ the service's settings: run it as docs/DEPLOYMENT.md shows.},
    'database.where_file'  => 'in {path}',
    'database.where_shell' => q{in your shell's environment},
);

# What says the text came from PostgreSQL: DBI's or DBD::Pg's own words
# around it, or libpq's "connection to server" in English or Italian. A
# refused connection or a missing socket is how a mail server, clamd or
# GlifiStore fails too, and a command that reports one of those must not be
# told to start PostgreSQL.
const my @FROM_POSTGRESQL => (
    qr/\b DBI \b/msx,
    qr/DBD::Pg/msx,
    qr/connection [ ] to [ ] server/msx,
    qr/connessione [ ] al [ ] server/msx,
);

# What libpq and PostgreSQL say, strongest first: the key each failure
# means, the value its first capture gives, and its wordings. The server's
# own words, not DBI's or DBIx::Class's around them, which change between
# versions; in English and in the Italian a server or a C library set to
# Italian uses (PostgreSQL's it.po, glibc's strerror).
const my @CLASSES => (
    [
        'database.unknown_database',
        'database',
        qr/database [ ] "([^"]+)" [ ] does [ ] not [ ] exist/msx,
        qr/il [ ] database [ ] "([^"]+)" [ ] non [ ] esiste/msx,
    ],
    [
        'database.unknown_role',
        'user',
        qr/role [ ] "([^"]+)" [ ] does [ ] not [ ] exist/msx,
        qr/il [ ] ruolo [ ] "([^"]+)" [ ] non [ ] esiste/msx,
    ],
    [
        'database.authentication',
        undef,
        qr/password [ ] authentication [ ] failed/msx,
        qr/autenticazione [ ] con [ ] password [ ] fallita/msx,
        qr/no [ ] password [ ] supplied/msx,
    ],
    [
        'database.no_hba', undef,
        qr/no [ ] pg_hba[.]conf [ ] entry/msx,
        qr/nessuna [ ] voce [ ] in [ ] pg_hba[.]conf/msx,
    ],
    [
        'database.unknown_host',
        'host',
        qr/could [ ] not [ ] translate [ ] host [ ] name [ ] "([^"]+)"/msx,
        qr/conversione [ ] del [ ] nome [ ] host [ ] "([^"]+)"/msx,
    ],
    [
        'database.refused',
        undef,
        qr/Connection [ ] refused/msx,
        qr/Connessione [ ] rifiutata/msx,
        qr/socket .* No [ ] such [ ] file [ ] or [ ] directory/msx,
    ],
    [
        'database.not_migrated',
        'relation',
        qr/relation [ ] "([^"]+)" [ ] does [ ] not [ ] exist/msx,
        qr/la [ ] relazione [ ] "([^"]+)" [ ] non [ ] esiste/msx,
    ],
);

const my $MIGRATE => 'gpforum migrate';

const my $DEFAULT_PORT => 5432;

# The operating system, the language and the environment the sentence is
# written for; each defaults to this process's own.
has os       => sub { return GPForum::OS->detect; };
has language => sub {
    return GPForum::Service::I18N::CliCatalog->language_of( \%ENV );
};
has catalog => sub ($self) {
    return GPForum::Service::I18N::CliCatalog->new(
        language => $self->language );
};
has environment => sub { return $ENV{GPFORUM_ENV} // 'development'; };

# The environment file the settings were read from, when the caller knows
# it, for the sentence to name in any environment: a development checkout
# whose settings the front door read from a file keeps them there, not in
# the shell. The operating system's in staging and production otherwise.
has environment_file => undef;    # optional: the operating system's otherwise

# The service's environment file, when this host has one and this process did
# not read it, else undef. The units and the file both set GPFORUM_ENV, so a
# command run by hand without it sees the development defaults -- no
# password, the default database -- instead of what the service sees, and
# the remedy is to load the file, not to change the role's password.
has unread_environment_file => sub ($self) {
    return undef if defined $self->environment_file;
    return undef if defined $ENV{GPFORUM_ENV};

    my $file = $self->os->environment_file;
    return -e $file ? $file : undef;
};

# Returns the key and the values of the sentence for an error's text, or
# undef when it is not a database failure this module knows.
sub classify ( $self, $text ) {
    return undef if !defined $text;
    return undef if !any { $text =~ $_ } @FROM_POSTGRESQL;

    for my $class (@CLASSES) {
        my ( $key, $captured, @wordings ) = @{$class};
        my ($wording) = grep { $text =~ $_ } @wordings;
        next if !defined $wording;

        my %parameters = ( _connection($text), %{ $self->_commands } );
        if ( defined $captured ) {
            ( $parameters{$captured} ) = $text =~ $wording;
        }
        return { key => $key, parameters => \%parameters };
    }

    return undef;
}

# The sentence an operator reads for an error's text, in this object's
# language, or undef when the text is not a database failure it knows.
sub sentence ( $self, $text ) {
    my $failure = $self->classify($text);
    return undef if !defined $failure;

    return $self->_sentence_of($failure);
}

# The sentence for a database without a table a command needs, which the
# command found missing by looking, not through PostgreSQL's error: gpforum
# partitions on a database never migrated planned the months of tables that
# were not there, and said nothing was wrong.
sub not_migrated ( $self, $relation ) {
    return $self->_sentence_of(
        {
            key        => 'database.not_migrated',
            parameters => { %{ $self->_commands }, relation => $relation },
        }
    );
}

sub _sentence_of ( $self, $failure ) {
    my $sentence = _filled( $self->template( $failure->{key} ),
        $self->_parameters($failure) );
    my $unread = $self->_unread_file;
    return defined $unread ? "$sentence $unread" : $sentence;
}

# The sentence in its two parts, what is wrong and what puts it right --
# each sentence says the one, a colon, then the other -- for a check that
# writes the remedy on a line of its own under the problem: { problem, fix,
# note }, the note saying when the command did not read the service's
# environment file. Undef when the text is not a database failure this
# module knows.
sub parts ( $self, $text ) {
    my $failure = $self->classify($text);
    return undef if !defined $failure;

    my $parameters = $self->_parameters($failure);
    my ( $problem, $fix ) = split /:[ ]/msx,
      $self->template( $failure->{key} ), 2;
    $fix //= q{};
    $fix =~ s/[.]\z//msx;

    return {
        problem => _filled( $problem, $parameters ),
        fix     => _filled( $fix,     $parameters ),
        note    => $self->_unread_file,
    };
}

# A key's template in this object's language, else in English.
sub template ( $self, $key ) {
    return $self->catalog->template($key)
      // ( exists $ENGLISH{$key} ? $ENGLISH{$key} : undef );
}

# Every key with its English, as en.po must carry it.
sub english ($class) {
    return {%ENGLISH};
}

# A second sentence when the command did not read the file the service
# reads, outside staging and production; else undef.
sub _unread_file ($self) {
    return undef if $self->environment =~ /\A (?: staging | production )/msx;

    my $file = $self->unread_environment_file;
    return undef if !defined $file;

    return _filled( $self->template('database.unread_file'),
        { path => $file } );
}

# A failure's values, with the commands in them filled in too.
sub _parameters ( $self, $failure ) {
    my %parameters = %{ $failure->{parameters} };
    $parameters{where} = $self->_where;
    for my $name (qw(start create_role create_database set_password)) {
        $parameters{$name} = _filled( $parameters{$name}, \%parameters );
    }

    return \%parameters;
}

sub _where ($self) {
    if ( !defined $self->environment_file
        && $self->environment !~ /\A (?: staging | production )/msx )
    {
        return $self->template('database.where_shell');
    }

    return _filled( $self->template('database.where_file'),
        { path => $self->environment_file // $self->os->environment_file } );
}

sub _commands ($self) {
    return { %{ $self->os->postgresql_packaging }, migrate => $MIGRATE };
}

# The server, role and database the failed connection named: libpq's own
# "connection to server at" first, then DBI's connect string.
sub _connection ($text) {
    my ( $source, $user ) = $text =~ /connect [(] '([^']*)' , '([^']*)'/msx;
    my %pairs = map { /\A \s* ([^=\s]+) = (.*) \z/msx ? ( $1, $2 ) : () }
      split /;/msx, $source // q{};

    my ($host)   = $text =~ /server [ ] at [ ] "([^"]+)"/msx;
    my ($port)   = $text =~ /" [^,]* , [ ] port [ ] (\d+) [ ] failed/msx;
    my ($socket) = $text =~ /server [ ] on [ ] socket [ ] "([^"]+)"/msx;
    $host //= $pairs{host};
    $port //= $pairs{port} // $DEFAULT_PORT;

    return (
        server   => $socket // ( defined $host ? "$host:$port" : "port $port" ),
        user     => $user   // 'gpforum',
        database => $pairs{dbname} // $pairs{database} // $pairs{db}
          // 'gpforum',
        host => $host // 'localhost',
    );
}

sub _filled ( $template, $parameters ) {
    return $template if !defined $template;
    $template =~ s{ [{] (\w+) [}] }
                  { exists $parameters->{$1} ? $parameters->{$1} : "{$1}" }gemsx;

    return $template;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::DatabaseFailure - One sentence for a database a command
cannot use.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $sentence =
      GPForum::Service::Operations::DatabaseFailure->new->sentence($error_text);
    # Cannot reach PostgreSQL at 127.0.0.1:5432 (connection refused): start
    # it with sudo systemctl start postgresql, or correct
    # GPFORUM_DATABASE_DSN in /etc/gpforum/gpforum.env.

=head1 DESCRIPTION

Reads what PostgreSQL said, through DBI, when a command could not use the
database -- the server refusing the connection, a host that does not
resolve, a password or pg_hba.conf refusal, a role or database that does not
exist, a table the migrations have not made -- and writes it as one
sentence that names the setting to correct, where the service reads it, and
the command that fixes it. L<GPForum::Command::Usage> uses it for every command's failure.

The sentence follows the operator's language, as the forum follows a
member's: Italian when the first of C<LC_ALL>, C<LC_MESSAGES> and C<LANG>
that is set starts with C<it>, English otherwise.

=head1 SUBROUTINES/METHODS

=head2 classify

Takes an error's text and returns C<< { key, parameters } >>: the message
key (C<database.refused>, C<database.unknown_host>,
C<database.authentication>, C<database.no_hba>, C<database.unknown_role>,
C<database.unknown_database> or C<database.not_migrated>) and the values its
sentence names. Returns undef for any other text, including a refused
connection or a missing socket that DBI, DBD::Pg or libpq did not report.

=head2 sentence

Takes an error's text and returns the sentence for it, or undef. A command
run without the service's environment file, on a host that has one, gets a
second sentence saying so.

=head2 not_migrated

Takes the name of a table a command found missing and returns the sentence
for a database the migrations have not made it in yet, with C<gpforum
migrate> as its remedy.

=head2 parts

Takes an error's text and returns its sentence as C<problem> and C<fix>, the
two halves either side of its colon, and C<note>, the second sentence
L</sentence> adds or undef; or undef for a text it does not know.

=head2 template

Takes a key and returns its template, with C<{name}> placeholders, from the
command-line catalog in this object's language, else in English.

=head2 english

Class method. Every key's English template, as C<locale/cli/en.po> must
carry it.

=head2 os

The L<GPForum::OS> profile whose environment file and PostgreSQL commands
the sentence names; the detected one by default.

=head2 language

C<en> or C<it>: by default the one L<GPForum::Service::I18N::CliCatalog>
reads from C<LC_ALL>, C<LC_MESSAGES> and C<LANG>.

=head2 catalog

The L<GPForum::Service::I18N::CliCatalog> the templates come from, in
L</language>.

=head2 environment

The C<GPFORUM_ENV> the sentence is for: in staging and production it names
the service's environment file, elsewhere the shell's environment.

=head2 environment_file

The environment file the settings were read from, which the sentence names
in every environment; without it, the operating system's in staging and
production and the shell's environment elsewhere.

=head2 unread_environment_file

The service's environment file (L<GPForum::OS> C<environment_file>) when it
exists on this host and C<GPFORUM_ENV> is not set, else undef. Outside
staging and production the sentence then adds that the command did not read
that file.

=head1 DIAGNOSTICS

None: a text it does not know gives undef.

=head1 CONFIGURATION AND ENVIRONMENT

Reads C<LC_ALL>, C<LC_MESSAGES>, C<LANG> and C<GPFORUM_ENV> unless they are
given. The environment file and the PostgreSQL commands it names come from
the operating system's L<GPForum::OS> profile.

=head1 DEPENDENCIES

L<Const::Fast>, L<List::Util>, L<Mojo::Base>, L<GPForum::OS>,
L<GPForum::Service::I18N::CliCatalog>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A failure PostgreSQL words differently, or in another language than English
(C<lc_messages>), is left as it was.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
