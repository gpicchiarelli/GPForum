# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::Backup;

use Carp qw(croak);
use Const::Fast;
use Cwd     qw(getcwd);
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File qw(path);
use Mojo::Util qw(encode);

use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Support::Words;
use GPForum::Command::Usage;
use GPForum::Service::Operations::Backup;
use GPForum::Service::Operations::Host;
use GPForum::X::Config;
use GPForum::X::Usage;

our $VERSION = '0.001';

const my $COMMAND    => 'gpforum-backup';
const my $CHECK_MARK => "\N{CHECK MARK} ";
const my $NOTE_MARK  => q{! };

# `gpforum backup [--to DIR]`: the database, the attachments and a manifest,
# in a new directory named for the instant (audit C5, owner decision D11).
# The work is GPForum::Service::Operations::Backup's; this says it.

has backup => sub { return GPForum::Service::Operations::Backup->new; };
has words  => sub { return GPForum::Command::Support::Words->new; };

# The directory the command was typed in, which the backup goes into
# without --to, and which a relative --to starts at: the front door runs
# the maintain verbs from the code directory.
has directory => sub { return getcwd(); };

has output => sub { return \*STDOUT; };
has errors => sub { return \*STDERR; };

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->help( $self->output, _usage() )
      if GPForum::Command::Usage->wants_help(@arguments);

    my $request;
    try {
        $request = _request(@arguments);
    }
    catch ($error) {
        return GPForum::Command::Usage->error(
            GPForum::Command::Usage->trimmed($error), _usage() )
          if GPForum::Command::Usage->is_usage($error);
        die $error;    ## no critic (ErrorHandling::RequireCarping) -- rethrows the caught error as it was raised
    };

    my $typed = $request->{to} // $self->directory;
    my $into =
      path($typed)->is_abs ? path($typed) : path( $self->directory, $typed );
    $into = path( $into->to_string =~ s{(?<=.)/+\z}{}rmsx );

    my $taken;
    try {
        my $refused = $self->backup->refusal($into) // $self->_clients_missing
          // $self->backup->make_room($into);
        return $self->_refused( $request, $refused ) if $refused;

        $taken = $self->backup->take($into);
    }
    catch ($error) {
        return GPForum::Command::Usage->failure( $error,
            $request->{json}
            ? ( $self->output, { command => $COMMAND } )
            : () );
    };

    return $self->_taken( $request, $taken );
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return <<'USAGE';
Usage: gpforum backup [--to DIR] [--json]

Backs the forum up into a new directory, named for the time it was taken
(gpforum-20261009T221530Z, in UTC), readable by this account alone:

  database.dump    the database GPFORUM_DATABASE_DSN names, as pg_dump's
                   custom format
  attachments.tar  the uploads, from GPFORUM_ATTACHMENT_ROOT
  manifest.json    the versions they came from, their sizes and SHA-256

Run it as the service's user, who can read both: sudo -u gpforum gpforum
backup --to /var/backups/gpforum. gpforum restore --check DIR then checks
that a backup can be restored. The settings, and their secrets, are not in
it: keep the environment file apart.

  --to DIR   where the backup's directory goes, made when it is not there;
             without it, the directory the command is typed in. Never the
             code directory, which an upgrade replaces
  --json     one JSON object on stdout instead of the lines
  --help     show this help

Exit status: 0 backed up, 1 it could not be, 2 usage error, 78 settings
gpforum cannot use.
USAGE
}

sub _request (@arguments) {
    my %request;
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
        _misuse( 'cli.backup.no_words', { word => $argument } );
    }

    return \%request;
}

# Why the backup cannot start for want of pg_dump, or undef.
sub _clients_missing ($self) {
    try {
        $self->backup->clients;
    }
    catch ($error) {
        return ['cli.backup.no_client'] if GPForum::X::Config->caught($error);
        die $error;    ## no critic (ErrorHandling::RequireCarping) -- rethrows the caught error as it was raised
    };

    return undef;
}

sub _refused ( $self, $request, $refused ) {
    my $sentence = $self->_said( @{$refused} );
    if ( $request->{json} ) {
        GPForum::Command::Usage->json(
            $self->output,
            {
                command => $COMMAND,
                status  => 'fail',
                error   => $sentence,
                key     => $refused->[0],
            }
        );
    }
    $self->_line( $self->errors, $sentence );

    return $GPForum::Command::Usage::EXIT_FAILURE;
}

sub _taken ( $self, $request, $taken ) {
    my $manifest  = $taken->{manifest};
    my $directory = $taken->{directory};
    my $check     = _as_this_account( 'gpforum restore --check '
          . GPForum::Service::Operations::Host->shell_word($directory) );
    if ( $request->{json} ) {
        GPForum::Command::Usage->json(
            $self->output,
            {
                command   => $COMMAND,
                status    => 'ok',
                directory => $directory,
                manifest  => $manifest,
                next      => [
                    GPForum::Command::Support::ServiceEnvironment->as_read(
                        $check)
                ],
            }
        );
        return $GPForum::Command::Usage::EXIT_OK;
    }

    my $backup   = $self->backup;
    my %size     = map { $_->{name} => $_->{bytes} } @{ $manifest->{files} };
    my $database = $manifest->{database};
    $self->_line(
        $self->output,
        $CHECK_MARK
          . $self->_said(
            defined $database->{schema}
            ? 'cli.backup.database'
            : 'cli.backup.database_bare',
            {
                database => $database->{name},
                size   => $backup->size_text( $size{ $backup->files->{dump} } ),
                schema => $database->{schema},
                server => $database->{server},
            }
          )
    );
    $self->_attachments( $manifest, \%size );
    $self->_line( $self->output,
            $CHECK_MARK
          . $self->_said( 'cli.backup.done', { directory => $directory } ) );
    $self->_line(
        $self->output,
        $self->_said(
            'cli.next',
            {
                step => $self->_said(
                    'cli.backup.next_check',
                    {
                        command => GPForum::Command::Support::ServiceEnvironment
                          ->as_read(
                            $check)
                    }
                )
            }
        )
    );

    return $GPForum::Command::Usage::EXIT_OK;
}

sub _attachments ( $self, $manifest, $size ) {
    my $attachments = $manifest->{attachments};
    if ( !$attachments ) {
        $self->_line(
            $self->output,
            $NOTE_MARK
              . $self->_said(
                'cli.backup.no_attachments',
                { root => $self->backup->attachment_root }
              )
        );
        return;
    }

    my $count = $attachments->{files};
    $self->_line(
        $self->output,
        $CHECK_MARK
          . $self->_said(
              $count == 1 ? 'cli.backup.attachments_one'
            : $count      ? 'cli.backup.attachments_many'
            : 'cli.backup.attachments_none',
            {
                count => $count,
                size  => $self->backup->size_text( $attachments->{bytes} ),
                root  => $attachments->{root},
            }
          )
    );

    return;
}

# The backup is readable by the account that took it alone: under sudo -u,
# the check offered runs as that account too, as it was typed.
sub _as_this_account ($command) {
    my $user = getpwuid $EFFECTIVE_USER_ID;
    my $sudo = $ENV{SUDO_USER};
    return $command
      if !defined $user || !defined $sudo || !length $sudo || $sudo eq $user;

    return $user eq 'root' ? "sudo $command" : "sudo -u $user $command";
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

GPForum::Command::Backup - C<gpforum backup>: the database, the
attachments and a manifest, in a dated directory.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::Command::Backup->new->run( '--to', '/var/backups/gpforum' );

=head1 DESCRIPTION

Takes a backup with L<GPForum::Service::Operations::Backup> and says what
it holds -- the database and its size, the attachments and theirs, the
directory -- and the command that checks it can be restored.

=head1 SUBROUTINES/METHODS

=head2 run

Takes the command line and returns the exit status: 0 backed up, 1 not, 2
misuse, 78 settings gpforum cannot use.

=head2 usage_text

Class method. The C<--help> text.

=head1 DIAGNOSTICS

A directory inside the code directory or the attachment root, a file, one
that cannot be made, and a host without C<pg_dump> are refused with a
sentence that says what to do, and exit status 1. A database that does not
answer is said as every command says it (L<GPForum::Command::Usage>), its
password never shown.

=head1 CONFIGURATION AND ENVIRONMENT

Reads the environment the front door loaded.

=head1 DEPENDENCIES

L<GPForum::Service::Operations::Backup>, L<GPForum::Command::Support::Words>,
L<GPForum::Command::Usage>.

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
