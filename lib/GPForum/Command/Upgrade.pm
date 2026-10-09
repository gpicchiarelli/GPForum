# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::Upgrade;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::Util qw(encode);

use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Support::Words;
use GPForum::Command::Usage;
use GPForum::Service::Operations::Dependencies;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::ReadinessFindings;
use GPForum::X::Usage;

our $VERSION = '0.001';

const my $COMMAND => 'gpforum-upgrade';
const my $INDENT  => q{  };

# Where the backup taken before an upgrade goes, as docs/ops/upgrade.md and
# backup-and-restore.md name it.
const my $BACKUPS => '/var/backups/gpforum';

# Walkthrough 3, friction 5: gpforum help named no upgrade, and the three
# commands lived in docs/ops/upgrade.md alone. gpforum upgrade prints them,
# written for this host -- its code directory, its service manager's
# restart, the service's account, and the --env-file this run read -- and
# runs none of them: the first needs root, and an upgrade is the operator's
# to start.

has host => sub { return GPForum::Service::Operations::Host->new; };

has service_environment =>
  sub { return GPForum::Command::Support::ServiceEnvironment->new; };

has dependencies =>
  sub { return GPForum::Service::Operations::Dependencies->new; };

has words => sub { return GPForum::Command::Support::Words->new; };

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->help( \*STDOUT, _usage() )
      if GPForum::Command::Usage->wants_help(@arguments);

    my $json = 0;
    for my $argument (@arguments) {
        if ( $argument eq '--json' ) {
            $json = 1;
            next;
        }
        return GPForum::Command::Usage->error(
            $self->_said(
                'cli.misuse.unknown_option', { option => $argument }
            ),
            _usage()
        );
    }

    my $plan = $self->plan;
    if ($json) {
        GPForum::Command::Usage->json(
            \*STDOUT,
            {
                command  => $COMMAND,
                status   => 'ok',
                steps    => $plan->{steps},
                restart  => $plan->{restart},
                backup   => $plan->{backup},
                deployed => $self->host->is_deployed ? 1 : 0,
            }
        );
        return 0;
    }

    return $self->_print($plan);
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints.
sub usage_text ($class) {
    return _usage();
}

# What to type, in order, as { steps, restart, backup }: the three
# commands; the restart said apart, when the host has no command for it to
# go after gpforum migrate; and the backup to take first, on a server.
sub plan ($self) {
    my $host     = $self->host;
    my $deployed = $host->is_deployed;
    my $root     = $host->shell_word( $self->dependencies->root );
    my $install  = $self->dependencies->install_command($deployed);
    my $runner =
      GPForum::Service::Operations::ReadinessFindings->service_user_prefix(
        $host);
    my $restart =
      $deployed ? $self->service_environment->restart_command : undef;

    my @steps = (
        $deployed
        ? "sudo git -C $root pull && $install"
        : "cd $root && git pull && $install",
        "${runner}gpforum migrate"
          . ( defined $restart ? " && $restart" : q{} ),
        "${runner}gpforum doctor --upgrade",
    );
    my $apart =
        defined $restart ? undef
      : $deployed        ? $self->_said('cli.restart_service')
      :                    $self->_said('cli.upgrade.restart_foreground');

    return {
        steps   => [ map { _as_read($_) } @steps ],
        restart => _as_read($apart),
        backup  => $deployed
        ? _as_read("${runner}gpforum backup --to $BACKUPS")
        : undef,
    };
}

sub _print ( $self, $plan ) {
    my @lines = (
        $self->_said('cli.upgrade.title'),            q{},
        ( map { $INDENT . $_ } @{ $plan->{steps} } ), q{},
    );
    if ( defined $plan->{restart} ) {
        push @lines,
          _as_read(
            $self->_said( 'cli.upgrade.restart', { step => $plan->{restart} } )
          );
    }
    push @lines, $self->_said('cli.upgrade.complete');
    if ( defined $plan->{backup} ) {
        push @lines,
          $self->_said( 'cli.upgrade.backup', { command => $plan->{backup} } );
    }
    push @lines, $self->_said('cli.upgrade.guide');

    print encode( 'UTF-8', join( "\n", @lines ) . "\n" )
      or croak 'failed to write the upgrade';

    return 0;
}

# A gpforum command it prints reads the file this run read, when that is not
# the host's own.
sub _as_read ($text) {
    return GPForum::Command::Support::ServiceEnvironment->as_read($text);
}

sub _said ( $self, $key, $parameters = {} ) {
    return $self->words->text( $key, $parameters );
}

sub _usage {
    return <<'USAGE';
Usage: gpforum upgrade [--json]

Prints the three commands that upgrade this forum, written for this host,
and runs none of them:

  1. the code and its dependencies (git pull, make install-deps-production)
  2. the schema, then the restart of the web service and the outbox worker
  3. gpforum doctor --upgrade, which says what the upgrade left behind

and the backup to take before them. docs/ops/upgrade.md says the same.

  --json   one JSON object on stdout: the commands, in order
  --help   show this help

Exit status: 0, 2 usage error.
USAGE
}

1;

__END__

=head1 NAME

GPForum::Command::Upgrade - The three commands that upgrade this forum.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    # gpforum upgrade
    exit GPForum::Command::Upgrade->new->run(@ARGV);

=head1 DESCRIPTION

C<gpforum upgrade> prints what F<docs/ops/upgrade.md> gives, written for
this host: the code and its dependencies from the code directory, then
C<gpforum migrate> and the restart this host's service manager needs, then
C<gpforum doctor --upgrade>. On a server they run as root and as the
service's account, with the backup to take before them; in development,
from the checkout, with the forum run by hand restarted after the
migration. A file read with C<--env-file> that is not the host's is named
in each C<gpforum> command. It runs none of them.

The restart is on the second line whatever the migration finds to apply:
the code changed, and the services read it only when they start.

=head1 SUBROUTINES/METHODS

=head2 run

Runs the command line. Returns 0, or 2 on misuse.

=head2 plan

The commands, as C<< { steps, restart, backup } >>: the three lines in
order, the restart said apart when there is no command for it to follow
C<gpforum migrate> (undef otherwise), and the backup to take first on a
server (undef in development).

=head2 host

The L<GPForum::Service::Operations::Host> the forum runs on.

=head2 service_environment

The L<GPForum::Command::Support::ServiceEnvironment> whose restart the
second line ends with.

=head2 dependencies

The L<GPForum::Service::Operations::Dependencies> that names the code
directory and the install command.

=head2 words

The operator's words, L<GPForum::Command::Support::Words>.

=head2 usage_text

The text C<--help> prints.

=head1 DIAGNOSTICS

Every sentence is in the operator's language; the C<--help> text is
English.

=head1 CONFIGURATION AND ENVIRONMENT

C<GPFORUM_ENV> decides between a server's commands and a development
checkout's.

=head1 DEPENDENCIES

L<GPForum::Command::Support::ServiceEnvironment>,
L<GPForum::Service::Operations::Dependencies>,
L<GPForum::Service::Operations::Host>,
L<GPForum::Service::Operations::ReadinessFindings>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

It prints the commands; it does not run them.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
