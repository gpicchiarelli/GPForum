# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::Backup;

use Carp qw(croak);
use Const::Fast;
use Cwd qw(realpath);
use Digest::SHA;
use English       qw(-no_match_vars);
use Errno         qw(EACCES);
use File::Find    qw(find);
use IPC::Open3    qw(open3);
use JSON::MaybeXS ();
use List::Util    qw(any maxstr);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File qw(path);
use POSIX      qw(WEXITSTATUS WIFEXITED strftime);
use Symbol     qw(gensym);

use GPForum::Config;
use GPForum::Migration::Runner;
use GPForum::Schema;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Findings;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::StagingDrill::PgTools;
use GPForum::X::Unavailable;

our $VERSION = '0.001';

# A routine backup (audit C5, owner decision D11): the database as pg_dump's
# custom format, the attachment root as a tar, and a manifest that says what
# they are -- the versions they came from, their sizes and their SHA-256 --
# in a directory of their own, named for the instant it was taken. The
# database keeps only the attachments' keys, so a dump alone restores a
# forum whose every attachment answers 404. Point-in-time recovery is
# PostgreSQL's own (docs/ops/backup-and-restore.md); this is the nightly
# copy an operator can carry off the host and check.

const my $FORMAT      => 1;
const my $KIND        => 'gpforum-backup';
const my $DUMP        => 'database.dump';
const my $ARCHIVE     => 'attachments.tar';
const my $MANIFEST    => 'manifest.json';
const my $PREFIX      => 'gpforum-';
const my $STAMP       => '%Y%m%dT%H%M%SZ';
const my $PRIVATE_DIR => oct '700';
const my $PRIVATE     => oct '077';
const my $KIBI        => 1024;
const my $SHA         => 256;
const my @UNITS       => qw(B KB MB GB TB);
const my $TAKEN       => qr/\A (\d{4}-\d\d-\d\d) T (\d\d:\d\d)/msx;

# pg_dump older than the server: "server version: 18.6 (Debian 18.6-1);
# pg_dump version: 16.4".
const my $SERVER_VERSION => qr/server [ ] version: [ ] (\d+) ([.\d]*) [^;]*/msx;
const my $CLIENT_VERSION => qr/pg_dump [ ] version: [ ] ([.\d]+)/msx;
const my $MISMATCH       => qr/$SERVER_VERSION ; [ ] $CLIENT_VERSION/msx;

# stat's field for the owner's uid.
const my $STAT_UID => 4;

# What a client says before its own words: "pg_dump: error: ", "tar: ".
const my $CLIENT_PREFIX =>
  qr/\A (?: [\w.-]+ : [ ] )? (?: (?: error | detail | hint ) : [ ] )?/msx;
const my $DELAYED => qr/Error [ ] exit [ ] delayed/msx;

# Two backups in one second get a second name, then a third.
const my $MAX_SAME_SECOND => 9;

const my %JSON_SETTINGS => ( canonical => 1, pretty => 1, utf8 => 1 );

# The settings: the database and the attachment root they name.
has config => sub { return GPForum::Config->from_environment; };

# pg_dump and pg_restore as found on this host; a check needs no settings.
has clients =>
  sub { return GPForum::Service::Operations::StagingDrill::PgTools->find; };

# The same, connecting as the settings' role.
has tools => sub ($self) {
    my $tools  = $self->clients;
    my $config = $self->config;
    my $secret = $config->database_password;

    return $tools->user( $config->database_user )
      ->password( defined $secret && length $secret ? $secret : undef );
};

# The code directory: an upgrade replaces it, so no backup is kept there.
has root => sub {
    return path(__FILE__)
      ->realpath->dirname->dirname->dirname->dirname->dirname->to_string;
};

has tar   => 'tar';
has clock => sub {
    return sub { return time }
};
has catalog => sub { return GPForum::Service::I18N::CliCatalog->new; };

# What the database is: its name, server and port, PostgreSQL's version and
# the latest migration applied. A test gives its own.
has database => sub ($self) { return $self->_read_database; };

sub files ($class) {
    return { dump => $DUMP, archive => $ARCHIVE, manifest => $MANIFEST };
}

# Why a backup is not written into a directory, as [ key, values ], or
# undef: the code directory, which an upgrade replaces; the attachment root,
# which the backup would copy into itself; a file.
sub refusal ( $self, $into ) {
    if ( -e $into && !-d $into ) {
        return [ 'cli.backup.not_directory', { directory => "$into" } ];
    }

    my $resolved = _resolved($into);
    my $root     = _resolved( $self->root );
    if ( _within( $resolved, $root ) ) {
        return [
            'cli.backup.in_code', { directory => "$into", root => $self->root }
        ];
    }
    my $attachments = $self->attachment_root;
    if ( _within( $resolved, _resolved($attachments) ) ) {
        return [
            'cli.backup.in_attachments',
            { directory => "$into", root => $attachments }
        ];
    }

    return undef;
}

# The directory made, when it is not there, readable by this account
# alone; or why it could not be, as [ key, values ].
sub make_room ( $self, $into ) {
    return undef if -d $into;

    my $old = umask $PRIVATE;
    my $failure;
    try {
        path($into)->make_path( { mode => $PRIVATE_DIR } );
    }
    catch ($error) {
        $failure = $error;
    };
    umask $old;
    return undef if !defined $failure;

    return [
        'cli.backup.cannot_make',
        {
            directory => "$into",
            typed     => _word("$into"),
            reason    => _reason($failure) =~ s/\A mkdir \s .*? : \s+//rmsx,
            user      => _user(),
        }
    ];
}

# The attachment root the settings name; a relative one starts at the code
# directory, as the service's units run from it.
sub attachment_root ($self) {
    my $root = $self->config->attachment_root =~ s{(?<=.)/+\z}{}rmsx;

    return path($root)->is_abs
      ? $root
      : path( $self->root, $root )->to_string;
}

# Takes the backup into a new directory under $into and returns
# { directory, manifest }. A backup that fails half-way is removed: a
# directory that holds a manifest holds a whole backup.
sub take ( $self, $into ) {
    my $room = $self->make_room($into);
    if ($room) {
        GPForum::X::Unavailable->throw(
            message => "cannot make $into: $room->[1]{reason}" );
    }
    my $database = $self->database;
    my $tools    = $self->tools;
    my $taken    = $self->clock->();
    my $place    = $self->_new_directory( $into, $taken );

    my $old = umask $PRIVATE;
    my $manifest;
    try {
        $self->_dump( $tools, $place, $database );
        my $attachments = $self->_archive( $place, $into );

        $manifest = {
            format   => $FORMAT,
            kind     => $KIND,
            taken    => strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime $taken ),
            database => $database,
            versions => {
                schema     => $database->{schema},
                postgresql => $database->{server},
                pg_dump    => $tools->version_of('pg_dump'),
            },
            attachments => $attachments,
            files       => [
                _described( $place, $DUMP ),
                (
                    $attachments
                    ? _described( $place, $ARCHIVE,
                        entries => $attachments->{files} )
                    : ()
                ),
            ],
        };
        $place->child($MANIFEST)
          ->spew( JSON::MaybeXS->new(%JSON_SETTINGS)->encode($manifest) );
    }
    catch ($error) {
        umask $old;
        $place->remove_tree;
        die $error;    ## no critic (ErrorHandling::RequireCarping) -- rethrows the caught error as it was raised
    };
    umask $old;

    return { directory => $place->to_string, manifest => $manifest };
}

# Whether a backup can be restored, without restoring it: its manifest, each
# file's size and SHA-256 against it, pg_restore reading the dump's table of
# contents and tar reading the archive. Returns { findings, manifest }.
sub check ( $self, $directory ) {
    my $findings =
      GPForum::Service::Operations::Findings->new( catalog => $self->catalog );

    # The directory gpforum backup --to was given, rather than a backup in
    # it: a pointer to its newest backup, not a failure.
    my $latest =
      -e path( $directory, $MANIFEST ) ? undef : $self->latest($directory);
    if ( defined $latest ) {
        $findings->add(
            name    => 'manifest',
            status  => 'degraded',
            message =>
              [ 'cli.restore.holds_backups', { directory => "$directory" } ],
        );
        return { findings => $findings, manifest => undef, latest => $latest };
    }

    my $manifest = $self->_manifest( $findings, $directory );
    if ( !$manifest ) {
        return { findings => $findings, manifest => undef };
    }

    my %listed = map { $_->{name} // q{} => 1 } @{ $manifest->{files} };
    for my $file ( @{ $manifest->{files} } ) {
        $self->_check_file( $findings, $directory, $file );
    }

    # A manifest that leaves out the dump, or the archive of the uploads it
    # says it copied, does not describe a whole backup.
    for my $wanted ( $DUMP, $manifest->{attachments} ? $ARCHIVE : () ) {
        next if $listed{$wanted};
        $findings->add(
            name    => $wanted,
            status  => 'fail',
            message => [ 'cli.restore.not_listed', { file => $wanted } ],
        );
    }
    if ( !$manifest->{attachments} ) {
        $findings->add(
            name    => 'attachments',
            status  => 'degraded',
            message => ['cli.restore.no_attachments'],
        );
    }

    return { findings => $findings, manifest => $manifest };
}

# The newest backup in a directory that holds backups, such as the one
# given to gpforum backup --to; undef when it holds none.
sub latest ( $self, $directory ) {
    return undef if !-d $directory || !-r _ || !-x _;

    my @backups = sort grep { -f path( $_, $MANIFEST ) }
      map { $_->to_string }
      path($directory)
      ->list( { dir => 1 } )
      ->grep(
        sub ($entry) { -d $entry && $entry->basename =~ /\A \Q$PREFIX\E/msx } )
      ->each;

    return @backups ? $backups[-1] : undef;
}

# A size as an operator reads it: 812 B, 4.2 MB. Italian writes 4,2 MB.
sub size_text ( $self, $bytes ) {
    my $unit = 0;
    my $size = $bytes // 0;
    while ( $size >= $KIBI && $unit < $#UNITS ) {
        $size /= $KIBI;
        $unit++;
    }
    my $number = $unit ? sprintf '%.1f', $size : sprintf '%d', $size;
    if ( $self->catalog->language eq 'it' ) {
        $number =~ tr/./,/;
    }

    return "$number $UNITS[$unit]";
}

# When a manifest says a backup was taken, as an operator reads it.
sub taken_text ( $self, $manifest ) {
    my ( $day, $time ) = ( $manifest->{taken} // q{} ) =~ $TAKEN;

    return defined $day ? "$day $time UTC" : $manifest->{taken} // q{};
}

sub _read_database ($self) {
    my $schema = GPForum::Schema->connect_from_config( $self->config );
    $schema->storage->ensure_connected;
    my $dbh = $schema->storage->dbh;
    my ( $name, $server ) = $dbh->selectrow_array(
        q{SELECT current_database(), current_setting('server_version')});
    my $applied =
      GPForum::Migration::Runner->new( schema => $schema )->applied_versions;
    my $schema_version = maxstr keys %{$applied};
    my $parts          = $self->tools->parse_dsn( $self->config->database_dsn );
    $schema->storage->disconnect;

    return {
        name   => $name,
        host   => $parts->{host} // q{},
        port   => $parts->{port} // q{},
        server => ( $server =~ /\A (\S+)/msx )[0],
        schema => $schema_version,
    };
}

# A directory named for the instant, made for this account alone.
sub _new_directory ( $self, $into, $taken ) {
    my $name = $PREFIX . strftime( $STAMP, gmtime $taken );
    for my $attempt ( 1 .. $MAX_SAME_SECOND ) {
        my $place = path( $into, $attempt == 1 ? $name : "$name-$attempt" );
        next if -e $place;
        if ( !mkdir $place, $PRIVATE_DIR ) {
            next if -e $place;
            GPForum::X::Unavailable->throw(
                message => "cannot make $place: $OS_ERROR" );
        }
        return $place;
    }

    GPForum::X::Unavailable->throw(
        message => "$into already holds the backups of $name" );
}

# pg_dump of the settings' database into the backup. A failure is said as
# the operator reads it: a pg_dump older than the server, with the client
# to install, or what pg_dump said -- never the command, nor a password.
sub _dump ( $self, $tools, $place, $database ) {
    try {
        $tools->dump_database( $self->config->database_dsn,
            $place->child($DUMP)->to_string );
    }
    catch ($error) {
        my $said = _client_said($error);
        my ( $major, $minor, $client ) = $said =~ $MISMATCH;
        GPForum::X::Unavailable->throw(
            cause   => $error,
            message => defined $major
            ? $self->catalog->text(
                'cli.backup.dump_older',
                {
                    client => $client,
                    server => "$major$minor",
                    major  => $major
                }
              )
            : $self->catalog->text(
                'cli.backup.dump_failed',
                { database => $database->{name}, said => $said }
            ),
        );
    };

    return;
}

# The attachment root as a tar, and what it held; undef when there is none.
# A root tar cannot read is said with the account that can: its owner.
sub _archive ( $self, $place, $into ) {
    my $root = $self->attachment_root;
    return undef if !-d $root;

    my ( $files, $bytes ) = ( 0, 0 );

    # tar says what it cannot read, and the failure says it again.
    no warnings qw(File::Find);    ## no critic (TestingAndDebugging::ProhibitNoWarnings) -- tar reports the directories find cannot open
    find(
        {
            no_chdir => 1,
            wanted   => sub {
                my @stat = lstat;
                return if !@stat || -d _;
                $files++;
                $bytes += -s _;
            },
        },
        $root
    );

    # macOS's tar would add an AppleDouble file for each one with extended
    # attributes.
    local $ENV{COPYFILE_DISABLE} = 1;
    try {
        $self->_run(
            [
                $self->tar, '-cf', $place->child($ARCHIVE)->to_string,
                '-C',       $root, q{.}
            ]
        );
    }
    catch ($error) {
        my $owner = _owner($root);
        my %said  = (
            root => $root,
            said => _client_said($error),
            user => _user(),
        );
        GPForum::X::Unavailable->throw(
            cause   => $error,
            message => defined $owner && $owner ne $said{user}
            ? $self->catalog->text(
                'cli.backup.archive_as_owner',
                {
                    %said,
                    owner   => $owner,
                    command => "sudo -u $owner gpforum backup --to "
                      . _word("$into"),
                }
              )
            : $self->catalog->text( 'cli.backup.archive_failed', \%said ),
        );
    };

    return { root => $root, files => $files, bytes => $bytes };
}

sub _manifest ( $self, $findings, $directory ) {
    my ( $manifest, $problem ) = $self->_read_manifest($directory);
    if ($problem) {
        $findings->add(
            name    => 'manifest',
            status  => 'fail',
            message => $problem,
        );
        return undef;
    }

    $findings->add(
        name    => 'manifest',
        status  => 'ok',
        message => [
            'cli.restore.manifest',
            {
                database => $manifest->{database}{name} // q{?},
                taken    => $self->taken_text($manifest),
                schema   => $manifest->{versions}{schema} // q{?},
            }
        ],
    );

    return $manifest;
}

# The manifest a directory holds, or why there is none to trust, as
# [ key, values ]: a path this account cannot read is said with the
# account that can, not as a directory that is not a backup.
sub _read_manifest ( $self, $directory ) {
    my $file       = path( $directory, $MANIFEST );
    my $unreadable = _unreadable( $directory, $file );
    if ( defined $unreadable ) {
        return (
            undef,
            [
                'cli.restore.cannot_read',
                { path => $unreadable, $self->_as_owner($directory) }
            ]
        );
    }

    my $said = { directory => "$directory" };
    return ( undef, [ 'cli.restore.no_directory', $said ] )
      if !-d $directory;
    return ( undef, [ 'cli.restore.no_manifest', $said ] ) if !-e $file;
    my $manifest = _decoded( $file->slurp );
    return ( undef, [ 'cli.restore.bad_manifest', $said ] )
      if !_is_manifest($manifest);
    return ( undef, [ 'cli.restore.newer_manifest', $said ] )
      if ( $manifest->{format} // 0 ) > $FORMAT;

    return ( $manifest, undef );
}

# What this account cannot read on the way to a manifest, or undef: the
# backup's directory, the directory of the backups above it when that is
# shut (0700, gpforum's), or the manifest itself.
sub _unreadable ( $directory, $file ) {
    if ( !-d $directory ) {
        return $OS_ERROR == EACCES ? "$directory" : undef;
    }
    return "$directory" if !-r _ || !-x _;
    return "$file"      if -e $file && !-r _;

    return undef;
}

# Whether decoded JSON has a manifest's shape.
sub _is_manifest ($manifest) {
    return 0
      if ref $manifest ne 'HASH' || ( $manifest->{kind} // q{} ) ne $KIND;
    return 0 if ref $manifest->{files} ne 'ARRAY';
    return 0 if any { ref ne 'HASH' } @{ $manifest->{files} };

    return ( ref( $manifest->{database} // {} ) eq 'HASH'
          && ref( $manifest->{versions} // {} ) eq 'HASH' ) ? 1 : 0;
}

# A manifest's JSON, or undef for text that is not JSON.
sub _decoded ($text) {
    my $decoded;
    try {
        $decoded = JSON::MaybeXS->new( utf8 => 1 )->decode($text);
    }
    catch ($error) {
        $decoded = undef;
    };

    return $decoded;
}

# One file against the manifest: there, as large, the same SHA-256, and
# readable by the program that restores it.
sub _check_file ( $self, $findings, $directory, $file ) {
    my $name = $file->{name} // q{};
    my $at   = path( $directory, $name );
    my %said = (
        file     => $name,
        size     => $self->size_text( $file->{bytes} ),
        expected => $self->size_text( $file->{bytes} ),
    );
    my $fail = sub ( $key, %more ) {
        $findings->add(
            name    => $name,
            status  => 'fail',
            message => [ $key, { %said, %more } ],
        );
        return;
    };

    return $fail->('cli.restore.missing')
      if $name =~ m{/|\A[.]}msx || !-f $at;
    return $fail->( 'cli.restore.file_cannot_read',
        $self->_as_owner($directory) )
      if !-r $at;
    my $bytes = -s $at;
    if ( !defined $file->{bytes} || $bytes != $file->{bytes} ) {
        return $fail->(
            'cli.restore.size_differs', size => $self->size_text($bytes)
        );
    }
    my $digest =
      Digest::SHA->new($SHA)->addfile( $at->to_string, 'b' )->hexdigest;
    return $fail->('cli.restore.checksum_differs')
      if $digest ne ( $file->{sha256} // q{} );

    return $self->_check_dump( $findings, $at, \%said, $fail )
      if $name eq $DUMP;
    return $self->_check_archive( $findings, $at, $file, \%said, $fail )
      if $name eq $ARCHIVE;

    $findings->add(
        name    => $name,
        status  => 'ok',
        message => [ 'cli.restore.file_ok', \%said ],
    );
    return;
}

sub _check_dump ( $self, $findings, $at, $said, $fail ) {
    my ( $listing, $tools );
    try {
        $tools = $self->clients;
    }
    catch ($error) {
        return $fail->('cli.restore.no_pg_restore');
    };
    try {
        $listing = $tools->list_dump( $at->to_string );
    }
    catch ($error) {
        return $fail->( 'cli.restore.dump_unreadable',
            reason => _reason($error) );
    };

    my $entries = grep { /\S/msx && !/\A ;/msx } split /\n/msx, $listing;
    $findings->add(
        name    => $DUMP,
        status  => 'ok',
        message => [ 'cli.restore.dump_ok', { %{$said}, entries => $entries } ],
    );

    return;
}

sub _check_archive ( $self, $findings, $at, $file, $said, $fail ) {
    my $listing;
    try {
        $listing = $self->_run( [ $self->tar, '-tf', $at->to_string ] );
    }
    catch ($error) {
        return $fail->( 'cli.restore.archive_unreadable',
            reason => _reason($error) );
    };

    my $files = grep { length && !m{/\z}msx } split /\n/msx, $listing;
    if ( defined $file->{entries} && $files != $file->{entries} ) {
        return $fail->(
            'cli.restore.archive_count',
            files    => $files,
            expected => $file->{entries}
        );
    }
    $findings->add(
        name    => $ARCHIVE,
        status  => 'ok',
        message => [
            $files == 1
            ? 'cli.restore.archive_ok_one'
            : 'cli.restore.archive_ok',
            { %{$said}, files => $files }
        ],
    );

    return;
}

# A program's output, standard error with it; a program that fails throws
# GPForum::X::Unavailable with what it said.
sub _run ( $self, $command ) {
    my $pid = open3( my $input, my $output, undef, @{$command} );
    close $input or croak "cannot close $command->[0]'s input: $OS_ERROR";
    my $said = do { local $INPUT_RECORD_SEPARATOR = undef; <$output> }
      // q{};
    close $output or croak "cannot close $command->[0]'s output: $OS_ERROR";
    waitpid $pid, 0;
    if ( !WIFEXITED($CHILD_ERROR) || WEXITSTATUS($CHILD_ERROR) != 0 ) {
        GPForum::X::Unavailable->throw(
            message => "$command->[0] failed:\n" . ( $said =~ s/\s+\z//msxr ) );
    }

    return $said;
}

# Who reads a backup the account running this cannot, and the check as
# them: the owner of the backup, or of the nearest directory above it this
# account can see -- the 0700 directory of the backups, say.
sub _as_owner ( $self, $directory ) {
    my $owner = _owner($directory) // 'gpforum';

    return (
        user    => _user(),
        owner   => $owner,
        command => "sudo -u $owner gpforum restore --check "
          . _word("$directory"),
    );
}

# The account that owns a path, or the nearest directory above it that can
# be seen; undef when none can.
sub _owner ($at) {
    my $place = path($at)->to_abs;
    my @stat  = stat $place;
    while ( !@stat && $place->dirname->to_string ne $place->to_string ) {
        $place = $place->dirname;
        @stat  = stat $place;
    }

    return @stat ? scalar getpwuid $stat[$STAT_UID] : undef;
}

sub _user {
    return scalar( getpwuid $EFFECTIVE_USER_ID ) // q{};
}

sub _word ($word) {
    return GPForum::Service::Operations::Host->shell_word($word);
}

# What pg_dump or tar said when it failed, in their own words without the
# command line: "aborting because of server version mismatch; server
# version: 18.6; pg_dump version: 16.4".
sub _client_said ($error) {
    my @lines = grep { /\S/msx } split /\n/msx, "$error";
    if (   @lines > 1
        && $lines[0] =~ /\A (?: pg [ ] command | \S+ ) [ ] failed/msx )
    {
        shift @lines;
    }
    my @said = grep { length && !/$DELAYED/msx }
      map { s/$CLIENT_PREFIX//rmsx =~ s/\A \s+ | \s+ \z//grmsx } @lines;

    return @said ? join q{; }, @said : _reason($error);
}

sub _described ( $place, $name, %more ) {
    my $file = $place->child($name)->to_string;

    return {
        name   => $name,
        bytes  => -s $file,
        sha256 => Digest::SHA->new($SHA)->addfile( $file, 'b' )->hexdigest,
        %more,
    };
}

# A path with every directory that exists resolved, symbolic links and all,
# and the rest as typed: one that does not exist yet still has a place.
sub _resolved ($typed) {
    my @rest;
    my $at = path($typed)->to_abs;
    while ( !-e $at && $at->to_string ne $at->dirname->to_string ) {
        unshift @rest, $at->basename;
        $at = $at->dirname;
    }
    my $real = realpath( $at->to_string ) // $at->to_string;

    return path( $real, @rest )->to_string;
}

sub _within ( $inner, $outer ) {
    return 1 if $inner eq $outer;
    my $base = $outer =~ s{/*\z}{/}rmsx;

    return index( $inner, $base ) == 0 ? 1 : 0;
}

# The last thing a failure said, without Perl's location.
sub _reason ($error) {
    my @lines = grep { /\S/msx } split /\n/msx, "$error";
    my $said  = @lines ? $lines[-1] : "$error";
    $said =~ s/\s+ at \s+ \S+ \s+ line \s+ \d+ [.]? \s* \z//msx;

    return $said =~ s/\A \s+|\s+ \z//grmsx;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::Backup - The routine backup: the database,
the attachments and a manifest, and the check that one can be restored.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $backup = GPForum::Service::Operations::Backup->new;
    my $refused = $backup->refusal('/var/backups/gpforum')
      // $backup->make_room('/var/backups/gpforum');
    my $taken = $backup->take('/var/backups/gpforum');
    # { directory => '/var/backups/gpforum/gpforum-20261009T221530Z',
    #   manifest  => { ... } }

    my $check = $backup->check( $taken->{directory} );
    print $check->{findings}->human_text( summary => 0 );

=head1 DESCRIPTION

C<gpforum backup> and C<gpforum restore --check>'s work. A backup is a
directory named C<gpforum-YYYYMMDDTHHMMSSZ>, readable by its owner alone,
holding F<database.dump> (C<pg_dump --format=custom> of the database the
settings name), F<attachments.tar> (the attachment root) and
F<manifest.json>: the format, when it was taken, the database's name,
server and versions -- the latest migration applied, PostgreSQL's and
pg_dump's -- what the attachment root held, and each file's size and
SHA-256. The manifest is written last, and a backup that fails half-way is
removed, so a directory with a manifest is a whole backup. No password is
written anywhere.

The check reads the manifest, compares each file's size and SHA-256 with
it, has C<pg_restore --list> read the dump's table of contents and C<tar
-tf> the archive, and counts the archive's files against the manifest. It
restores nothing.

=head1 SUBROUTINES/METHODS

=head2 config

The settings (L<GPForum::Config>), read from the environment by default.

=head2 clients

C<pg_dump> and C<pg_restore> as found on this host
(L<GPForum::Service::Operations::StagingDrill::PgTools>).

=head2 tools

The same, connecting as the settings' role.

=head2 root

The code directory, which no backup is written into.

=head2 tar

The C<tar> program, found on C<PATH> by default.

=head2 clock

A sub that returns the time, in epoch seconds.

=head2 catalog

The command-line catalog the findings are said in.

=head2 database

What the database is: C<name>, C<host>, C<port>, C<server> (PostgreSQL's
version) and C<schema> (the latest migration applied), read from it.

=head2 files

Class method. The names of the dump, the archive and the manifest.

=head2 refusal

Takes a directory and returns why no backup is written into it, as a
catalog key and its values, or undef: the code directory, the attachment
root, or a file.

=head2 make_room

Takes a directory and makes it, readable by this account alone, when it is
not there. Returns undef, or why it could not, as a catalog key and its
values.

=head2 attachment_root

The attachment root the settings name, absolute.

=head2 take

Takes a directory and writes a new backup into it. Returns the backup's
C<directory> and C<manifest>.

=head2 check

Takes a backup's directory and returns its C<findings>
(L<GPForum::Service::Operations::Findings>) and C<manifest>. A directory
with no manifest that holds backups -- the one C<gpforum backup --to> was
given -- returns a C<degraded> finding that says so, and C<latest>, the
newest backup in it, with nothing checked.

=head2 latest

Takes a directory and returns the newest backup in it -- the last
C<gpforum-*> directory by name that holds a manifest -- or undef.

=head2 size_text

Takes a number of bytes and returns it as an operator reads it, such as
C<4.2 MB>, with a decimal comma in Italian.

=head2 taken_text

Takes a manifest and returns when the backup was taken, such as
C<2026-10-09 22:15 UTC>.

=head1 DIAGNOSTICS

L</take> throws L<GPForum::X::Unavailable> when the database, C<pg_dump> or
C<tar> fails, L<GPForum::X::Config> when the settings cannot be used or
C<pg_dump> is not found.

=head1 CONFIGURATION AND ENVIRONMENT

C<GPFORUM_DATABASE_DSN>, C<GPFORUM_DATABASE_USER>,
C<GPFORUM_DATABASE_PASSWORD> (given to pg_dump as C<PGPASSWORD>, for that
command only), C<GPFORUM_ATTACHMENT_ROOT>, C<GPFORUM_PG_DUMP> and
C<GPFORUM_PG_RESTORE>.

=head1 DEPENDENCIES

L<Digest::SHA>, L<File::Find>, L<IPC::Open3>, L<JSON::MaybeXS>,
L<GPForum::Service::Operations::Findings>,
L<GPForum::Service::Operations::StagingDrill::PgTools>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The attachments are copied after the dump, as the files are while tar reads
them: an upload made meanwhile is an unreferenced file in the archive, and
an attachment erased meanwhile is referenced by the dump and missing from
the archive. The DSN's options other
than the database, server and port (such as C<sslmode>) are not given to
pg_dump; libpq's environment variables (C<PGSSLMODE>) are.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
