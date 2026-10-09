# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::Restore;

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
use GPForum::X::Usage;

our $VERSION = '0.001';

const my $COMMAND => 'gpforum-restore';
const my $GUIDE   => 'docs/ops/backup-and-restore.md';

# `gpforum restore --check DIR`: whether a backup gpforum backup took can be
# restored -- its manifest, each file's size and SHA-256, pg_restore reading
# the dump, tar reading the archive -- without restoring it. A restore
# replaces a forum, so it is done by hand, with the guide's steps; this is
# the question to answer before, and every night after the backup.

has backup => sub { return GPForum::Service::Operations::Backup->new; };
has words  => sub { return GPForum::Command::Support::Words->new; };

# The directory the command was typed in, which a relative DIR starts at.
has directory => sub { return getcwd(); };

has output => sub { return \*STDOUT; };

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

    my $typed = $request->{check} =~ s{(?<=.)/+\z}{}rmsx;
    my $from =
      path($typed)->is_abs ? path($typed) : path( $self->directory, $typed );
    my $checked  = $self->backup->check( $from->to_string );
    my $findings = $checked->{findings};

    # A directory of backups is a pointer to its newest, and nothing in it
    # was checked: not a sound backup either.
    my $sound = !$findings->exit_status && $checked->{manifest};

    if ( $request->{json} ) {
        GPForum::Command::Usage->json(
            $self->output,
            {
                command   => $COMMAND,
                status    => $findings->status,
                directory => $from->to_string,
                findings  => $findings->document,
                (
                    defined $checked->{latest}
                    ? ( latest => $checked->{latest} )
                    : ()
                ),
            }
        );
    }
    else {
        $self->_print( $checked, $sound );
    }

    return $sound
      ? $GPForum::Command::Usage::EXIT_OK
      : $GPForum::Command::Usage::EXIT_FAILURE;
}

# The findings, then whether the backup can be restored and what to do: a
# directory that is not a backup has its newest backup offered instead,
# when it holds one.
sub _print ( $self, $checked, $sound ) {
    my $findings = $checked->{findings};
    my @lines    = ( $findings->human_text( summary => 0 ) =~ s/\n\z//rmsx );

    # A file this account cannot read says how to check it as the backup's
    # owner; whether the backup can be restored is not known yet.
    my $unread = grep { $_->{message}[0] eq 'cli.restore.file_cannot_read' }
      @{ $findings->items };
    if ( !$checked->{manifest} || $unread ) {
        if ( defined $checked->{latest} ) {
            push @lines,
              $self->_next(
                'cli.restore.next_latest',
                {
                    command => 'gpforum restore --check '
                      . GPForum::Service::Operations::Host->shell_word(
                        $checked->{latest}
                      )
                }
              );
        }
    }
    elsif ($sound) {
        push @lines, q{}, $self->_said('cli.restore.sound'),
          $self->_next( 'cli.restore.next_restore', { guide => $GUIDE } );
    }
    else {
        push @lines, q{}, $self->_said('cli.restore.unsound'),
          $self->_next('cli.restore.next_backup');
    }

    my $text = join( "\n", @lines ) . "\n";
    print { $self->output }
      encode( 'UTF-8',
        GPForum::Command::Support::ServiceEnvironment->as_read($text) )
      or croak "cannot print: $OS_ERROR";

    return;
}

sub _next ( $self, $key, $parameters = {} ) {
    return $self->_said( 'cli.next',
        { step => $self->_said( $key, $parameters ) } );
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return <<'USAGE';
Usage: gpforum restore --check DIR [--json]

Checks that a backup gpforum backup took can be restored, and restores
nothing: its manifest; each file's size and SHA-256 against it; that
pg_restore reads the database dump's table of contents; that tar reads the
attachments and finds as many files as the backup wrote.

Restoring a backup replaces the forum's database and uploads, so it is done
by hand: the steps are in docs/ops/backup-and-restore.md.

  --check DIR  the backup's directory, gpforum-YYYYMMDDTHHMMSSZ
  --json       one JSON object on stdout instead of the lines
  --help       show this help

Exit status: 0 it can be restored, 1 it cannot, 2 usage error.
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
        if ( $argument =~ /\A --check (?: = (.*) )? \z/msx ) {
            my $value = $1 // shift @arguments;
            if ( !defined $value || !length $value ) {
                _misuse( 'cli.misuse.missing_value', { option => '--check' } );
            }
            $request{check} = $value;
            next;
        }
        if ( $argument =~ /\A -/msx ) {
            _misuse( 'cli.misuse.unknown_option', { option => $argument } );
        }
        _misuse( 'cli.restore.needs_check', { guide => $GUIDE } );
    }
    if ( !defined $request{check} ) {
        _misuse( 'cli.restore.needs_check', { guide => $GUIDE } );
    }

    return \%request;
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

GPForum::Command::Restore - C<gpforum restore --check>: whether a backup
can be restored, without restoring it.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::Command::Restore->new->run( '--check',
        '/var/backups/gpforum/gpforum-20261009T221530Z' );

=head1 DESCRIPTION

Checks a backup with L<GPForum::Service::Operations::Backup>: a line for
the manifest and for each file, marked as C<gpforum doctor> marks its
findings, then whether the backup can be restored and what to do next.

=head1 SUBROUTINES/METHODS

=head2 run

Takes the command line and returns the exit status: 0 the backup can be
restored, 1 it cannot, 2 misuse.

=head2 usage_text

Class method. The C<--help> text.

=head1 DIAGNOSTICS

C<gpforum restore> without C<--check> is misuse: it says that restoring is
done by hand, and where the steps are.

=head1 CONFIGURATION AND ENVIRONMENT

C<GPFORUM_PG_RESTORE> names C<pg_restore> when it is not on C<PATH>.

=head1 DEPENDENCIES

L<GPForum::Service::Operations::Backup>, L<GPForum::Command::Support::Words>,
L<GPForum::Command::Usage>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

It reads what pg_restore and tar read; it does not restore into a scratch
database. C<gpforum staging-drill> rehearses a whole restore.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
