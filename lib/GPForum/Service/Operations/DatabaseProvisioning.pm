# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::DatabaseProvisioning;

use Carp qw(croak);
use Const::Fast;
use Crypt::URandom ();
use DBI;
use Digest::SHA   qw(hmac_sha256 sha256);
use English       qw(-no_match_vars);
use JSON::MaybeXS ();
use MIME::Base64  qw(encode_base64);
use Mojo::Base -base, -signatures;
use v5.40;
use POSIX ();

use GPForum::OS;

our $VERSION = '0.001';

# What gpforum setup does with PostgreSQL before the migrations: it finds
# the forum's role and database, and makes the ones missing as the server's
# superuser when it can reach one, or says the statements that make them
# when it cannot.

const my $DEFAULT_PORT => 5432;

# The hosts that are this one: "create on this host" may reach the server's
# superuser through its local socket.
const my %LOCAL_HOST => map { $_ => 1 } ( q{}, qw(127.0.0.1 localhost ::1) );

# PostgreSQL's own SCRAM-SHA-256 defaults (scram_iterations, and the salt
# length its clients use).
const my $SCRAM_ITERATIONS => 4_096;
const my $SCRAM_SALT_BYTES => 16;

# Where getpwnam puts the ids and the home.
const my $ENTRY_UID  => 2;
const my $ENTRY_GID  => 3;
const my $ENTRY_HOME => 7;

# An identifier psql and a shell read as it is; any other is quoted.
const my $PLAIN_IDENTIFIER => qr/\A [[:lower:]_] [[:lower:][:digit:]_]* \z/msx;

const my %CONNECT_OPTIONS => (
    AutoCommit => 1,
    PrintError => 0,
    RaiseError => 1,
);

has os => sub { return GPForum::OS->detect; };

# Who this process runs as: root may become the server's own account.
has effective_uid => sub { return $EFFECTIVE_USER_ID; };

# The operator who ran it through sudo, whose own role a server like
# Homebrew's trusts.
has sudo_user => sub { return $ENV{SUDO_USER}; };

# How root reaches the server's superuser on this host -- { account, role,
# sockets } -- or undef; GPForum::OS's by default, a test's own.
has superuser_account => sub ($self) {
    return $self->os->postgresql_superuser;
};

# The superuser logins the shell setup was started in gives, besides
# libpq's own: GPFORUM_DATABASE_USER and GPFORUM_DATABASE_PASSWORD, as a CI
# runner or an automation sets them for a server that takes only a password
# over TCP, where libpq alone logged in as nobody it knew. Each a { user,
# password, from }; %ENV's the first time they are asked for, and setup
# gives its own, read before it loads the file it wrote, whose
# GPFORUM_DATABASE_USER is the forum's own role.
has given_logins => sub { return __PACKAGE__->logins_of( \%ENV ); };

# A data source's database, host and port: { database, host, port }, or
# undef for one that is not PostgreSQL's (dbi:Pg:...).
sub data_source ( $class, $dsn ) {
    return undef if !defined $dsn;
    my ($pairs) = $dsn =~ /\A dbi:Pg: (.*) \z/msxi;
    return undef if !defined $pairs;

    my %value =
      map { /\A \s* ([^=\s]+) \s* = \s* (.*?) \s* \z/msx ? ( lc $1, $2 ) : () }
      split /;/msx, $pairs;

    return {
        database => $value{dbname} // $value{database} // $value{db},
        host     => $value{host}   // q{},
        port     => $value{port}   // $DEFAULT_PORT,
        (
            map { exists $value{$_} ? ( $_ => $value{$_} ) : () }
              qw(user password)
        ),
    };
}

# The superuser login an environment gives: GPFORUM_DATABASE_USER and its
# password, when the user is set. A list of { user, password, from }.
sub logins_of ( $class, $environment ) {
    my $user = $environment->{GPFORUM_DATABASE_USER};
    return [] if !defined $user || !length $user;

    return [
        {
            user     => $user,
            password => $environment->{GPFORUM_DATABASE_PASSWORD} // q{},
            from     => 'GPFORUM_DATABASE_USER',
        }
    ];
}

# What libpq said, without DBI's words around it: "role "x" does not exist",
# "password authentication failed for user "x"", "fe_sendauth: no password
# supplied". The text as it was when it is none of libpq's.
sub reason_of ( $class, $error ) {
    return q{} if !defined $error;
    my $text = $error =~ s/\s+ at \s+ \S+ \s+ line \s+ \d+ [.]? \s* \z//rmsx;
    my ($said) =
         $text =~ /(?: FATAL | FATALE ) : \s+ (.+) \z/msx
      || $text =~ / failed: \s+ (?! connection [ ] to [ ] server) (.+) \z/msx
      || $text =~ /port [ ] \d+ [ ] failed: \s+ (.+) \z/msx
      ? ($1)
      : ($text);

    return $said =~ s/\s+/ /grmsx =~ s/\A \s+ | \s+ \z//grmsx;
}

# The server as an operator reads it: host:port, or the socket directory and
# port.
sub server_name ( $class, $source ) {
    my $host = length $source->{host} ? $source->{host} : 'localhost';

    return "$host:$source->{port}";
}

# Whether the server is on this host, where root may reach its superuser
# over the local socket.
sub is_local ( $class, $source ) {
    return 1 if exists $LOCAL_HOST{ $source->{host} };

    return $source->{host} =~ m{\A /}msx ? 1 : 0;
}

# The verifier PostgreSQL keeps in place of a password, as its own clients
# compute it before they send CREATE ROLE or \password: the server, and its
# log, never see the password itself. SCRAM-SHA-256 (RFC 5802, RFC 7677)
# over the password's UTF-8; SASLprep leaves an ASCII password as it is.
sub scram_verifier ( $class, $password, %options ) {
    my $salt = $options{salt} // Crypt::URandom::urandom($SCRAM_SALT_BYTES);
    my $iterations = $options{iterations} // $SCRAM_ITERATIONS;
    my $key        = $password;
    utf8::encode($key);

    # Hi(): PBKDF2 with HMAC-SHA-256, one block.
    my $block  = hmac_sha256( $salt . pack( 'N', 1 ), $key );
    my $salted = $block;
    for ( 2 .. $iterations ) {
        $block = hmac_sha256( $block, $key );
        $salted ^.= $block;
    }
    my $stored = sha256( hmac_sha256( 'Client Key', $salted ) );
    my $server = hmac_sha256( 'Server Key', $salted );

    return sprintf 'SCRAM-SHA-256$%d:%s$%s:%s', $iterations,
      map { encode_base64( $_, q{} ) } $salt, $stored, $server;
}

# Undef when the role connects to the data source with the password, else
# what DBI said, for GPForum::Service::Operations::DatabaseFailure to read.
sub connection_error ( $self, %target ) {
    my $error;
    try {
        my $handle =
          DBI->connect( $target{dsn}, $target{user}, $target{password} // q{},
            {%CONNECT_OPTIONS} );
        $handle->disconnect;
    }
    catch ($caught) {
        $error = "$caught";
    };

    return $error;
}

# What the server holds for the forum, asked of its superuser: { superuser,
# role, database } -- who answered (you, or the server's own account), and
# whether the role and the database exist -- or { superuser => undef,
# error } when no superuser answers.
sub inspect ( $self, %target ) {
    my $source = $self->data_source( $target{dsn} );
    my ( $user, $database ) = ( $target{user}, $source->{database} );

    my $result = $self->_as_superuser(
        $source,
        sub ($handle) {
            return _holds( $handle, $user, $database );
        }
    );
    if ( defined $result->{failed} ) {
        croak $result->{failed};
    }

    return $result;
}

# Makes the role, with the password's verifier, and the database it owns,
# each when it is missing. Returns { superuser, role_made, database_made },
# or { superuser => undef, error } when no superuser answers; croaks when a
# statement fails.
sub provision ( $self, %target ) {
    my $source = $self->data_source( $target{dsn} );
    my ( $user, $database ) = ( $target{user}, $source->{database} );
    my $verifier = $self->scram_verifier( $target{password} );

    my $result = $self->_as_superuser(
        $source,
        sub ($handle) {
            my $held = _holds( $handle, $user, $database );
            my %made = ( role_made => 0, database_made => 0 );
            if ( !$held->{role} ) {
                $handle->do( 'CREATE ROLE '
                      . $handle->quote_identifier($user)
                      . ' LOGIN PASSWORD '
                      . $handle->quote($verifier) );
                $made{role_made} = 1;
            }
            if ( !$held->{database} ) {
                $handle->do( 'CREATE DATABASE '
                      . $handle->quote_identifier($database)
                      . ' OWNER '
                      . $handle->quote_identifier($user) );
                $made{database_made} = 1;
            }
            return \%made;
        }
    );
    if ( defined $result->{failed} ) {
        croak $result->{failed};
    }

    return $result;
}

# The two statements an operator runs as the server's superuser when this
# process cannot: psql commands, each a line to type. The role's password is
# given as its verifier, so no secret is printed and none reaches the
# server's log. Given role_exists, the database's alone: a CREATE ROLE for a
# role the server has fails with "already exists".
sub commands ( $self, %target ) {
    my $source = $self->data_source( $target{dsn} );
    my $psql   = $self->os->postgresql_psql;
    my @where  = ();

    # A socket directory is named too: psql's own default is the package's,
    # which a server with its socket elsewhere does not answer in. A local
    # address is left out, so the superuser comes in over the socket.
    if ( !$self->is_local($source) || $source->{host} =~ m{\A /}msx ) {
        push @where, '-h', _shell_word( $source->{host} );
    }
    if ( $source->{port} != $DEFAULT_PORT ) {
        push @where, '-p', $source->{port};
    }
    my $user     = _identifier( $target{user} );
    my $database = _identifier( $source->{database} );
    my @role =
      $target{role_exists}
      ? ()
      : "CREATE ROLE $user LOGIN PASSWORD '"
      . $self->scram_verifier( $target{password} // q{} ) . q{'};

    return [
        map { join q{ }, $psql, @where, '-c', _shell_quoted($_) } @role,
        "CREATE DATABASE $database OWNER $user",
    ];
}

# Runs a piece of work with a handle on the server's superuser and returns
# its result with { superuser, as, from }: who answered -- you, given, or
# the server's account -- the superuser role it was, and, for a given login,
# where it came from. Tried in turn: this process's own account, as libpq
# picks it (PGUSER, PGPASSWORD, ~/.pgpass, the login name) -- Homebrew's
# PostgreSQL trusts the operator who installed it; under sudo, the operator
# who typed it; the login the data source names, then the environment's
# (given_logins); then, for root on a host whose server runs under an
# account of its own, that account over the local socket, in a child process
# that drops to it. { superuser => undef, error, tried } when none answers
# as a superuser: tried lists each { as, from, reason }.
sub _as_superuser ( $self, $source, $work ) {
    my @tried;
    for my $login ( $self->_logins($source) ) {
        my $own =
          $self->_connect_superuser( _admin_dsn( $source, $source->{host} ),
            $login->{user}, $login->{password} );
        if ( ref $own ) {
            my ($as) = $own->selectrow_array('SELECT current_user');
            my $result = _run_work( $own, $work );
            $own->disconnect;
            return {
                %{$result},
                superuser => $login->{from} ? 'given' : 'you',
                as        => $as,
                ( $login->{from} ? ( from => $login->{from} ) : () ),
            };
        }
        push @tried,
          {
            as     => _login_name( $login->{user} ),
            reason => $self->reason_of($own),
            ( $login->{from} ? ( from => $login->{from} ) : () ),
          };
    }

    my $account = $self->superuser_account;
    if (   $self->effective_uid == 0
        && defined $account
        && $self->is_local($source) )
    {
        my $socket = _socket_directory( $account, $source->{port} );
        if ( defined $socket ) {
            my $result =
              $self->_as_account( $account, $source, $socket, $work );
            return {
                %{$result},
                superuser => $account->{account},
                as        => $account->{role},
              }
              if !defined $result->{unreached};
            push @tried,
              {
                as     => $account->{role},
                from   => "account $account->{account}",
                reason => $self->reason_of( $result->{unreached} ),
              };
        }
    }

    return {
        superuser => undef,
        error     => @tried ? $tried[-1]{reason} : undef,
        tried     => \@tried,
    };
}

# The logins tried as this process: libpq's default (PGUSER, else the login
# name), then, under sudo, the operator who typed it -- Homebrew's superuser
# is the account that installed it, and sudo made this process root -- then
# the data source's own user and password, and the environment's, each once.
sub _logins ( $self, $source ) {
    my $operator = $self->sudo_user;
    my @logins   = (
        { user => q{}, password => q{} },
        $self->effective_uid == 0 && defined $operator && length $operator
        ? { user => $operator, password => q{} }
        : (),
    );
    if ( defined $source->{user} && length $source->{user} ) {
        push @logins,
          {
            user     => $source->{user},
            password => $source->{password} // q{},
            from     => 'GPFORUM_DATABASE_DSN',
          };
    }
    push @logins, @{ $self->given_logins // [] };

    my %seen;
    return grep { !$seen{"$_->{user}\0$_->{password}"}++ } @logins;
}

# The role a login is, as libpq picks it for an empty user: PGUSER, else the
# login name.
sub _login_name ($user) {
    return $user        if length $user;
    return $ENV{PGUSER} if defined $ENV{PGUSER} && length $ENV{PGUSER};

    return scalar( getpwuid $EFFECTIVE_USER_ID ) // q{};
}

# A handle on the server as a role that may make roles and databases, or
# the reason there is none.
sub _connect_superuser ( $self, $dsn, $user, $password = q{} ) {
    my $handle;
    try {
        $handle = DBI->connect( $dsn, $user, $password, {%CONNECT_OPTIONS} );
    }
    catch ($error) {
        return "$error";
    };
    my ($super) =
      $handle->selectrow_array(
        'SELECT rolsuper FROM pg_roles WHERE rolname = current_user');
    return $handle if $super;

    my ($name) = $handle->selectrow_array('SELECT current_user');
    $handle->disconnect;

    return "role $name is not a superuser";
}

# The work, done in a child process that runs as the server's account and
# connects through the socket, where peer authentication lets it in. The
# result comes back as JSON through a pipe; the child leaves with _exit, so
# nothing of the parent's -- a temporary file, a handle, a test's plan -- is
# cleaned up twice.
sub _as_account ( $self, $account, $source, $socket, $work ) {
    my @entry = getpwnam $account->{account};
    return { unreached => "there is no account $account->{account}" }
      if !@entry;

    pipe my $reader, my $writer or croak "pipe: $OS_ERROR";
    my $child = fork // croak "fork: $OS_ERROR";
    if ( !$child ) {
        close $reader or POSIX::_exit(1);
        my $result;
        try {
            _become( @entry[ $ENTRY_UID, $ENTRY_GID, $ENTRY_HOME ] );
            my $handle =
              $self->_connect_superuser( _admin_dsn( $source, $socket ),
                $account->{role} );
            $result =
              ref $handle
              ? _run_work( $handle, $work )
              : { unreached => $handle };
        }
        catch ($error) {
            $result = { unreached => "$error" };
        };
        print {$writer} JSON::MaybeXS->new( utf8 => 1 )->encode($result)
          or POSIX::_exit(1);
        close $writer or POSIX::_exit(1);
        POSIX::_exit(0);
    }

    close $writer or croak "close: $OS_ERROR";
    my $text = do { local $INPUT_RECORD_SEPARATOR = undef; <$reader> };
    close $reader or croak "close: $OS_ERROR";
    waitpid $child, 0;

    return { unreached => "the child running as $account->{account} failed" }
      if !defined $text || !length $text;

    return JSON::MaybeXS->new( utf8 => 1 )->decode($text);
}

# Drops this process to an account: its group, then its user, and its
# home, where libpq looks for ~/.pgpass. A process already running as it
# stays as it is.
sub _become ( $uid, $gid, $home ) {
    if ( $REAL_USER_ID != $uid || $EFFECTIVE_USER_ID != $uid ) {
        POSIX::setgid($gid) or croak "setgid $gid: $OS_ERROR";
        $EFFECTIVE_GROUP_ID = "$gid $gid";    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the child drops its groups for good
        POSIX::setuid($uid) or croak "setuid $uid: $OS_ERROR";
        croak "still running as $EFFECTIVE_USER_ID"
          if $REAL_USER_ID != $uid || $EFFECTIVE_USER_ID != $uid;
    }
    $ENV{HOME} = $home;                       ## no critic (Variables::RequireLocalizedPunctuationVars) -- the child's own environment

    return;
}

sub _run_work ( $handle, $work ) {
    my $result;
    try {
        $result = $work->($handle);
    }
    catch ($error) {
        $result = { failed => "$error" };
    };

    return $result;
}

sub _holds ( $handle, $user, $database ) {
    my ($role) =
      $handle->selectrow_array( 'SELECT 1 FROM pg_roles WHERE rolname = ?',
        undef, $user );
    my ($held) =
      $handle->selectrow_array( 'SELECT 1 FROM pg_database WHERE datname = ?',
        undef, $database );

    return { role => $role ? 1 : 0, database => $held ? 1 : 0 };
}

# The data source in the server's own database, postgres, on the host
# given: the forum's own may not exist yet.
sub _admin_dsn ( $source, $host ) {
    my @pairs = ( 'dbname=postgres', "port=$source->{port}" );
    if ( length $host ) {
        unshift @pairs, "host=$host";
    }

    return 'dbi:Pg:' . join q{;}, @pairs;
}

# The first of the package's socket directories that holds the server's
# socket for this port.
sub _socket_directory ( $account, $port ) {
    my ($directory) =
      grep { -S "$_/.s.PGSQL.$port" } @{ $account->{sockets} // [] };

    return $directory;
}

sub _identifier ($name) {
    return $name if $name =~ $PLAIN_IDENTIFIER;

    return q{"} . ( $name =~ s/"/""/grmsx ) . q{"};
}

# A word a shell reads as it is, else single-quoted.
sub _shell_word ($text) {
    return $text if $text =~ m{\A [[:alnum:]_./:@%+=-]+ \z}msx;

    return q{'} . ( $text =~ s/'/'\\''/grmsx ) . q{'};
}

# A statement as a shell reads it inside double quotes.
sub _shell_quoted ($text) {
    return q{"} . ( $text =~ s/(["\\\$`])/\\$1/grmsx ) . q{"};
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::DatabaseProvisioning - The forum's role and
database, made as PostgreSQL's superuser.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $database = GPForum::Service::Operations::DatabaseProvisioning->new;
    my %target   = (
        dsn      => 'dbi:Pg:dbname=gpforum;host=127.0.0.1;port=5432',
        user     => 'gpforum',
        password => $password,
    );
    my $made = $database->provision(%target);
    print "$_\n" for @{ $database->commands(%target) } if !$made->{superuser};

=head1 DESCRIPTION

C<gpforum setup> asks for the forum's database; this makes it. It reaches
the server's superuser as libpq would for this account -- Homebrew's
PostgreSQL trusts the operator who installed it, whose role it also tries
under sudo -- then with the login the data source or the environment gives
(C<user=> and C<password=> in the data source, C<GPFORUM_DATABASE_USER> and
C<GPFORUM_DATABASE_PASSWORD>), or, run as root on a host whose server runs
under an account of its own (C<postgres> on Debian and FreeBSD), as that
account over the local socket, in a child process that drops to it. It says
which way in it used, and, when none answered, what libpq said to each. It
then makes the forum's role, with its password, and the database the role
owns, each only when it is missing.

The password reaches the server as its SCRAM-SHA-256 verifier, as psql's
C<\password> and C<createuser --pwprompt> send it, so neither the server's
log nor the statements printed for an operator who must run them by hand
carry it.

=head1 SUBROUTINES/METHODS

=head2 given_logins

The superuser logins tried after libpq's own, each a C<{ user, password,
from }>: L</logins_of> C<%ENV> unless given.

=head2 data_source

Class method. Takes a DBI data source and returns its C<database>, C<host>
(empty for libpq's default socket) and C<port>, and its C<user> and
C<password> when it names them, or undef when it is not PostgreSQL's.

=head2 logins_of

Class method. Takes an environment and returns the superuser login it gives,
C<GPFORUM_DATABASE_USER> and C<GPFORUM_DATABASE_PASSWORD>, as a list of
C<{ user, password, from }>; empty when the user is not set.

=head2 reason_of

Class method. What libpq said in a DBI error, without DBI's words around it.

=head2 server_name

Class method. The server of a data source as an operator reads it,
C<host:port>.

=head2 is_local

Class method. Whether a data source's server is on this host.

=head2 scram_verifier

Class method. Takes a password and, optionally, C<salt> and C<iterations>,
and returns the C<SCRAM-SHA-256$...> verifier PostgreSQL stores for it.

=head2 connection_error

Takes C<dsn>, C<user> and C<password>; returns undef when the role
connects, else what DBI said.

=head2 inspect

Takes C<dsn> and C<user> and returns C<superuser> (C<you>, C<given>, the
server's account, or undef when no superuser answered, with C<error> and
C<tried>, each C<{ as, from, reason }>), C<as> (the superuser role) and, for
a given login, C<from>, then C<role> and C<database>, each 1 when it exists.
Croaks when the question fails.

=head2 provision

Takes C<dsn>, C<user> and C<password>, makes the role and the database each
when missing, and returns C<superuser>, C<role_made> and C<database_made>;
or C<superuser> undef, with C<error>, when no superuser answered. Croaks
when a statement fails.

=head2 commands

Takes C<dsn>, C<user> and C<password> and returns the two psql commands that
make the role, with the password's verifier, and the database, as this
host's superuser runs them; with C<role_exists>, the database's alone.

=head1 DIAGNOSTICS

C<provision> croaks with PostgreSQL's own words when a statement fails.

=head1 CONFIGURATION AND ENVIRONMENT

Reaching the superuser as this account reads libpq's C<PGUSER>,
C<PGPASSWORD> and F<~/.pgpass>, as psql does, and, run as root,
C<SUDO_USER>; then C<GPFORUM_DATABASE_USER> and C<GPFORUM_DATABASE_PASSWORD>
(L</given_logins>).

=head1 DEPENDENCIES

L<DBI> and DBD::Pg, L<Digest::SHA>, L<MIME::Base64>, L<Crypt::URandom>,
L<JSON::MaybeXS>, L<GPForum::OS> (the server's account and sockets, and its
psql).

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Becoming the server's account needs root. A password with characters
SASLprep maps differently than their UTF-8 is hashed as its UTF-8; the
passwords gpforum setup makes are hexadecimal.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
