# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::Service;

use Carp qw(croak);
use Const::Fast;
use Cwd     qw(getcwd);
use English qw(-no_match_vars);
use File::Temp;
use List::Util qw(any);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File qw(path);
use Mojo::Util qw(encode);

use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Support::Words;
use GPForum::Command::Usage;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::ServiceFiles;
use GPForum::X::Usage;

our $VERSION = '0.001';

const my $COMMAND    => 'gpforum-service';
const my $CHECK_MARK => "\N{CHECK MARK} ";
const my $NOTE_MARK  => q{! };
const my $STEP       => q{  };

const my $STAT_MODE    => 2;
const my $STAT_OWNER   => 4;
const my $OTHERS_WRITE => oct '002';

# `gpforum service print`: the service files deploy/ ships, written for this
# host -- its code directory, its environment file, the forum's public name
# and the address the application listens on -- printed for the operator
# to read and copy. It installs nothing (owner decision D8): every file
# ends with the commands that put it in place and start it, for the operator
# to type.

# The environment the front door read, which the files are written for.
has files => sub {
    my $read = GPForum::Command::Support::ServiceEnvironment->loaded;
    my $host = GPForum::Service::Operations::Host->new(
        defined $read ? ( environment_file => $read ) : () );
    return GPForum::Service::Operations::ServiceFiles->new(
        host => $host,
        defined $read ? ( environment_file => $read ) : (),
    );
};

has words => sub { return GPForum::Command::Support::Words->new; };

# The directory the command was typed in, which a relative --to starts at:
# the front door runs the verbs that set a forum up from the code
# directory.
has directory => sub { return getcwd(); };

has output => sub { return \*STDOUT; };
has errors => sub { return \*STDERR; };

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->help( $self->output, _usage() )
      if GPForum::Command::Usage->wants_help(@arguments);

    my $request;
    try {
        $request = $self->_request(@arguments);
    }
    catch ($error) {
        return GPForum::Command::Usage->error(
            GPForum::Command::Usage->trimmed($error), _usage() )
          if GPForum::Command::Usage->is_usage($error);
        die $error;    ## no critic (ErrorHandling::RequireCarping) -- rethrows the caught error as it was raised
    };

    my $files = $self->files->render( $request->{target}, $request->{names} );
    my $notes = [ map { $self->_said( @{$_} ) }
          @{ $self->files->notes( $request->{target} ) } ];

    return defined $request->{to}
      ? $self->_written( $request, $files, $notes )
      : $self->_printed( $request, $files, $notes );
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return <<'USAGE';
Usage: gpforum service print [TARGET] [FILE...] [--to DIR] [--json]

Prints the service files GPForum ships, written for this host: the code
directory, the environment file gpforum reads, the forum's address from
GPFORUM_PUBLIC_BASE_URL and the one the application listens on from
GPFORUM_RUNTIME_LISTEN. It installs nothing; it ends with the commands that
put the files in place and start them.

  systemd    the web service, the outbox worker and the two timers (Linux)
  rc         the rc scripts and the crontab of the jobs (FreeBSD)
  launchd    the web service, the outbox worker and the two jobs (macOS)
  nginx      the proxy site, with TLS, the upload limit and /metrics kept
             to this host
  caddy      the same, for Caddy

Without a TARGET, the service manager of this host. FILE prints only the
files named, such as gpforum-outbox.service.

  --to DIR   write the files into DIR: the directory this host reads them
             from (/etc/systemd/system, /Library/LaunchDaemons, rc.d,
             nginx's sites-enabled), where each goes in place and nothing
             else there is touched; or a directory of your own, to read
             them before copying them, which holds only them
  --json     one JSON object on stdout instead of the files
  --help     show this help

The files go to standard output and the steps to standard error, so
`gpforum service print nginx | sudo tee FILE` writes the file alone.

Exit status: 0 printed, 1 DIR could not be written, 2 usage error.
USAGE
}

# The command line: print, then a target, the files and the options.
sub _request ( $self, @arguments ) {
    my $action = shift @arguments;
    if ( !defined $action || $action ne 'print' ) {
        _misuse('cli.service.needs_print');
    }

    my ( $request, $words ) = _options(@arguments);
    my $services = 'GPForum::Service::Operations::ServiceFiles';
    my $targets  = join q{, }, @{ $services->targets };
    my $target =
      @{$words} && $services->is_target( $words->[0] )
      ? shift @{$words}
      : $self->files->default_target;
    if ( !defined $target ) {
        _misuse( 'cli.service.no_target', { targets => $targets } );
    }

    my @names = @{ $self->files->names($target) };
    my %known = map { $_ => 1 } @names;
    for my $name ( grep { !$known{$_} } @{$words} ) {
        _misuse(
            'cli.service.unknown_file',
            {
                name    => $name,
                target  => $target,
                names   => join( q{, }, @names ),
                targets => $targets,
            }
        );
    }

    return { %{$request}, target => $target, names => $words };
}

# The options, --json and --to DIR, and the words around them.
sub _options (@arguments) {
    my ( %request, @words );
    while (@arguments) {
        my $argument = shift @arguments;
        if ( $argument eq '--json' ) {
            $request{json} = 1;
            next;
        }
        if ( $argument =~ /\A --to (?: = (.*) )? \z/msx ) {
            my $value = $1 // shift @arguments;
            if ( !defined $value || !length $value ) {
                _misuse( 'cli.misuse.missing_value', { option => '--to' } );
            }
            $request{to} = $value;
            next;
        }
        if ( $argument =~ /\A -/msx ) {
            _misuse( 'cli.misuse.unknown_option', { option => $argument } );
        }
        push @words, $argument;
    }

    return ( \%request, \@words );
}

# The files on standard output, the steps on standard error: printed into a
# file or a pipe, the output is the file alone.
sub _printed ( $self, $request, $files, $notes ) {
    my $steps = $self->files->steps(
        $request->{target},
        start => 1,
        @{ $request->{names} } ? ( names => $request->{names} ) : ()
    );
    if ( $request->{json} ) {
        return $self->_document( $request, $files, $notes, $steps, 1 );
    }

    my $several = @{$files} > 1;
    my @texts =
      map { ( $several ? "==> $_->{path} <==\n" : q{} ) . $_->{text} }
      @{$files};
    print { $self->output } encode( 'UTF-8', join "\n", @texts )
      or croak "cannot print the files: $OS_ERROR";

    $self->_tell( $self->errors, $notes,
        $several ? 'cli.service.next_many' : 'cli.service.next_one', $steps );

    return $GPForum::Command::Usage::EXIT_OK;
}

# The files written into a directory: the one this host's service manager
# or proxy reads them from, where each goes in place under the name it is
# installed with, and the steps then start them; or another, for the
# operator to read, and the steps copy them from there.
sub _written ( $self, $request, $files, $notes ) {
    my $typed = $request->{to} =~ s{(?<=.)/+\z}{}rmsx;
    my $into =
      path($typed)->is_abs ? path($typed) : path( $self->directory, $typed );
    my $in_place = $self->_in_place( $request->{target}, $into );

    my $refused = $self->_refused( $request, $into, $typed, $in_place )
      // ( $in_place ? $self->_uncertified($files) : undef );
    return $self->_failed( $request, $refused ) if defined $refused;

    try {
        _write_all( $into, $files, $in_place );
    }
    catch ($error) {
        return $self->_failed(
            $request,
            $self->_said(
                'cli.service.cannot_write',
                {
                    directory => $typed,
                    reason    => GPForum::Command::Usage->trimmed($error)
                }
            )
        );
    };

    my $steps = $self->files->steps(
        $request->{target},
        ( $in_place ? ( in_place => 1 ) : ( from => $typed ) ),
        start => 1,
        @{ $request->{names} } ? ( names => $request->{names} ) : ()
    );
    if ( $request->{json} ) {
        return $self->_document( $request, $files, $notes, $steps, 0,
            $into->to_string );
    }

    my $one = @{$files} == 1;
    $self->_line(
        $self->output,
        $CHECK_MARK
          . $self->_said(
            $one ? 'cli.service.wrote_one' : 'cli.service.wrote_many',
            {
                count     => scalar @{$files},
                target    => $request->{target},
                directory => $typed,
                files     => join( q{, }, map { $_->{name} } @{$files} ),
            }
          )
    );
    $self->_tell( $self->output, $notes, _next_key( $in_place, $one ), $steps );

    return $GPForum::Command::Usage::EXIT_OK;
}

# What the steps after the files do: start them, in place; read them first,
# anywhere else.
sub _next_key ( $in_place, $one ) {
    return $one
      ? 'cli.service.next_in_place_one'
      : 'cli.service.next_in_place_many'
      if $in_place;

    return $one ? 'cli.service.next_read_one' : 'cli.service.next_read_many';
}

# Whether a directory is the one this host reads the target's files from --
# /etc/systemd/system, /Library/LaunchDaemons, rc.d, nginx's sites-enabled --
# where --to puts them in place.
sub _in_place ( $self, $target, $into ) {
    my $here = $into->to_string;

    return ( any { $_->{destination} eq $here }
          @{ $self->files->files($target) } ) ? 1 : 0;
}

# Why a proxy's site is not put in place, or undef: nginx refuses a site
# whose certificate is not there yet, and a reload with it would take every
# site the proxy serves down, so the certificate comes first.
sub _uncertified ( $self, $files ) {
    for my $file ( @{$files} ) {
        my ($certificate) =
          $file->{text} =~ /^ \s* ssl_certificate \s+ ([^;\s]+) ;/msx;
        next if !defined $certificate || $self->files->exists->($certificate);

        return $self->_said(
            'cli.service.no_certificate',
            {
                certificate => $certificate,
                command     => $self->files->certificate_command
                  // 'certbot certonly',
            }
        );
    }

    return undef;
}

# Each file written into the directory, or, in place, into the directory it
# goes in under the name it is installed with.
sub _write_all ( $into, $files, $in_place ) {
    $into->make_path;
    for my $file ( @{$files} ) {
        if ( !$in_place ) {
            _replace( $into, $file );
            next;
        }
        my $here = path( $file->{destination} );
        $here->make_path;
        _replace( $here, { %{$file}, name => $file->{installed} } );
    }

    return;
}

# One file written beside its name and renamed onto it, so a link left
# under that name is replaced, not followed: run through sudo, writing
# through a link would overwrite, and chmod, whatever it points at.
sub _replace ( $into, $file ) {
    my $temporary = File::Temp->new(
        DIR      => $into->to_string,
        TEMPLATE => ".$file->{name}.XXXXXX",
        UNLINK   => 0,
    );
    my $written = path( $temporary->filename );
    try {
        print {$temporary} encode( 'UTF-8', $file->{text} )
          or croak "cannot write $written: $OS_ERROR";
        close $temporary or croak "cannot close $written: $OS_ERROR";
        $written->chmod( $file->{mode} );
        rename $written->to_string, $into->child( $file->{name} )->to_string
          or croak "cannot rename $written: $OS_ERROR";
    }
    catch ($error) {
        unlink $written->to_string;
        die $error;    ## no critic (ErrorHandling::RequireCarping) -- rethrows the caught error as it was raised
    };

    return;
}

# Why a directory is not written into, or undef: one that holds anything
# but this target's files would have them copied with its own, a link or a
# directory under one of their names is not one of them, and one another
# account can change could have the files changed before they are copied
# into place. The directory the host reads them from holds other files of
# its own, which are left as they are; there only a directory under one of
# the names is refused, since a file renamed onto a link replaces the link.
sub _refused ( $self, $request, $into, $typed, $in_place = 0 ) {
    return undef if !-e $into;
    if ( !-d $into ) {
        return $self->_said( 'cli.service.not_directory',
            { directory => $typed } );
    }
    if ( !_own_directory($into) ) {
        return $self->_said( 'cli.service.open_directory',
            { directory => $typed } );
    }
    if ($in_place) {
        my @directories = sort grep { !-l && -d }
          map { $_->{path} } @{ $self->files->files( $request->{target} ) };
        return undef if !@directories;

        return $self->_said( 'cli.service.not_files',
            { directory => $typed, files => join q{, }, @directories } );
    }

    my %ours = map { $_ => 1 } @{ $self->files->names( $request->{target} ) };
    my @entries = $into->list( { dir => 1, hidden => 1 } )->each;
    my @others  = sort grep { !$ours{$_} } map { $_->basename } @entries;
    if (@others) {
        return $self->_said(
            'cli.service.foreign_files',
            {
                directory => $typed,
                target    => $request->{target},
                files     => join( q{, }, @others ),
            }
        );
    }

    my @linked = sort map { $_->basename } grep { _not_a_file($_) } @entries;
    return undef if !@linked;

    return $self->_said( 'cli.service.not_files',
        { directory => $typed, files => join q{, }, @linked } );
}

# A link, a directory or anything else but a plain file of its own.
sub _not_a_file ($entry) {
    return -l $entry || !-f $entry;
}

# A directory only this account, root, or the operator who typed sudo can
# change: the files written there are copied into place as root.
sub _own_directory ($into) {
    my ( $mode, $owner ) = ( stat $into )[ $STAT_MODE, $STAT_OWNER ];
    return 0 if !defined $mode || $mode & $OTHERS_WRITE;

    my %trusted = map { $_ => 1 } $EFFECTIVE_USER_ID, 0,
      grep { defined && /\A \d+ \z/msx } $ENV{SUDO_UID};
    return $trusted{$owner} ? 1 : 0;
}

sub _failed ( $self, $request, $sentence ) {
    if ( $request->{json} ) {
        GPForum::Command::Usage->json(
            $self->output,
            {
                command => $COMMAND,
                target  => $request->{target},
                status  => 'fail',
                error   => $sentence,
            }
        );
    }
    $self->_line( $self->errors, $sentence );

    return $GPForum::Command::Usage::EXIT_FAILURE;
}

sub _document ( $self, $request, $files, $notes, $steps, $texts,
    $directory = undef )
{
    GPForum::Command::Usage->json(
        $self->output,
        {
            command => $COMMAND,
            status  => 'ok',
            target  => $request->{target},
            ( defined $directory ? ( directory => $directory ) : () ),
            files => [
                map {
                    {
                        name     => $_->{name},
                        path     => $_->{path},
                        template => $_->{template},
                        ( $texts ? ( text => $_->{text} ) : () ),
                    }
                } @{$files}
            ],
            notes => $notes,
            next  => [
                map {
                    GPForum::Command::Support::ServiceEnvironment->as_read($_)
                } @{$steps}
            ],
        }
    );

    return $GPForum::Command::Usage::EXIT_OK;
}

# The notes, then the next steps, one command a line under a sentence that
# says what they do.
sub _tell ( $self, $handle, $notes, $key, $steps ) {
    for my $note ( @{$notes} ) {
        $self->_line( $handle, $NOTE_MARK . $note );
    }
    return if !@{$steps};

    $self->_line( $handle,
        $self->_said( 'cli.next', { step => $self->_said($key) } ) );
    for my $step ( @{$steps} ) {
        $self->_line( $handle,
            $STEP
              . GPForum::Command::Support::ServiceEnvironment->as_read($step) );
    }

    return;
}

sub _line ( $self, $handle, $text ) {
    print {$handle} encode( 'UTF-8', "$text\n" )
      or croak "cannot print: $OS_ERROR";

    return;
}

sub _said ( $self, $key, $parameters = {} ) {
    return $self->words->text( $key, $parameters );
}

sub _misuse ( $key, $parameters = {} ) {
    GPForum::X::Usage->throw( message =>
          GPForum::Command::Support::Words->new->text( $key, $parameters ) );
}

1;

__END__

=head1 NAME

GPForum::Command::Service - C<gpforum service print>: the service files,
written for this host.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::Command::Service->new->run( 'print', 'systemd',
        '--to', 'units' );

=head1 DESCRIPTION

Prints the systemd units, the FreeBSD rc scripts and crontab, the launchd
property lists, or the nginx or Caddy site that F<deploy/> ships, with this
host's code directory, environment file, public name and listen address in
place of the templates' own
(L<GPForum::Service::Operations::ServiceFiles>), followed by the commands
that put them in place and start them. With C<--to DIR> it writes them into
a directory to read first. It installs nothing.

=head1 SUBROUTINES/METHODS

=head2 run

Takes the command line and returns the exit status: 0 printed or written,
1 the directory could not be written, 2 misuse.

=head2 usage_text

Class method. The C<--help> text.

=head1 DIAGNOSTICS

A directory that holds anything but the target's files, or a link or a
directory under one of their names, one another account can change, one
that is a file, or one that cannot be written is refused with a sentence
that says so, and exit status 1. Each file is written beside its name and
renamed onto it, so a link is replaced, never followed.

=head1 CONFIGURATION AND ENVIRONMENT

Reads the environment the front door loaded (L<GPForum::Command::Support::ServiceEnvironment>).

=head1 DEPENDENCIES

L<GPForum::Service::Operations::ServiceFiles>,
L<GPForum::Command::Support::Words>, L<GPForum::Command::Usage>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
