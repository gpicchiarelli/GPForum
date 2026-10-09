# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::Doctor;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::Util qw(encode);

use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Usage;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Dependencies;
use GPForum::Service::Operations::Findings;
use GPForum::Service::Operations::Host;

# The checks themselves are loaded when they run, not with the command: they
# load most of the application, and a module an upgrade added and nobody
# installed would stop gpforum doctor --upgrade -- the command that says so
# -- with Perl's own error (_unloaded).

# What Perl says when a module, or one it uses, cannot be loaded.
const my $NOT_FOUND  => qr/Can't [ ] locate [ ] \S+ [ ] in [ ] \@INC/msx;
const my $NOT_LOADED => qr/Compilation [ ] failed [ ] in [ ] require/msx;

our $VERSION = '0.001';

const my $COMMAND => 'gpforum-doctor';

has catalog => sub { return GPForum::Service::I18N::CliCatalog->new; };

# The checks, for a test; otherwise GPForum::Service::Operations::Doctor on
# the environment the front door loaded.
has doctor => undef;    # optional: built from the options otherwise

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->help( \*STDOUT, _usage() )
      if GPForum::Command::Usage->wants_help(@arguments);

    my $options;
    try {
        $options = GPForum::Command::Usage->parse_options(
            \@arguments,
            { json => 0, upgrade => 0 },
            {
                switches => {
                    '--json'    => { json    => 1 },
                    '--upgrade' => { upgrade => 1 },
                },
                usage => _usage(),
            }
        );
    }
    catch ($error) {
        return GPForum::Command::Usage->error(
            GPForum::Command::Usage->trimmed($error), _usage() )
          if GPForum::Command::Usage->is_usage($error);
        die $error;    ## no critic (ErrorHandling::RequireCarping) -- rethrows the caught error as it was raised
    };

    my $result;
    try {
        $result = $self->_doctor($options)->check;
    }
    catch ($error) {
        my $unloaded = $self->_unloaded( $options, $error );
        return $self->_report( $options, $unloaded ) if $unloaded;

        return GPForum::Command::Usage->failure( $error,
            $options->{json}
            ? ( \*STDOUT, { command => $COMMAND, findings => [] } )
            : () );
    };

    return $self->_report( $options, $result );
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints.
sub usage_text ($class) {
    return _usage();
}

sub _doctor ( $self, $options ) {
    return $self->doctor if $self->doctor;

    require GPForum::Service::Operations::Doctor;    # see _unloaded

    my $environment = 'GPForum::Command::Support::ServiceEnvironment';
    return GPForum::Service::Operations::Doctor->new(
        catalog  => $self->catalog,
        file     => $environment->loaded,
        assigned => $environment->assigned,
        upgrade  => $options->{upgrade},
    );
}

# The checks could not be loaded: when a module the release needs is
# missing, or built for another Perl, that is what doctor says, with the
# command that installs them, instead of Perl's error. Returns the result
# _report writes, or undef for an error that is not that.
sub _unloaded ( $self, $options, $error ) {
    return undef
      if $self->doctor
      || ( "$error" !~ $NOT_FOUND && "$error" !~ $NOT_LOADED );

    my $dependencies = GPForum::Service::Operations::Dependencies->new;
    my $checked      = $dependencies->check_after($error);
    return undef if $checked->{status} eq 'ok';

    my $findings =
      GPForum::Service::Operations::Findings->new( catalog => $self->catalog );
    $dependencies->findings(
        $checked,
        $findings,
        $dependencies->install_command(
            GPForum::Service::Operations::Host->new(
                catalog => $self->catalog
            )->is_deployed
        )
    );

    return { findings => $findings, waiting => 0 };
}

sub _report ( $self, $options, $result ) {
    my $findings = $result->{findings};
    my $exit     = $findings->exit_status;

    if ( $options->{json} ) {
        GPForum::Command::Usage->json(
            \*STDOUT,
            {
                command  => $COMMAND,
                findings => GPForum::Command::Support::ServiceEnvironment
                  ->findings_as_read(
                    $findings->document
                  ),
                mode     => $options->{upgrade} ? 'upgrade' : 'check',
                problems => scalar @{ $findings->problems },
                status   => $findings->status,
                waiting  => $result->{waiting} ? 1 : 0,
            }
        );
        return $exit;
    }

    my $text = $findings->human_text( summary => 0 );
    if ( $result->{waiting} ) {
        $text .= "\n" . $self->catalog->text('doctor.waiting') . "\n";
    }
    $text .= "\n" . $findings->summary . "\n";
    print encode(
        'UTF-8',
        GPForum::Command::Support::ServiceEnvironment->as_read(
            GPForum::Command::Usage->as_invoked($text)
        )
    ) or croak 'failed to write the doctor report';

    return $exit;
}

sub _usage {
    return <<'USAGE';
Usage: gpforum doctor [--upgrade] [--json]

Checks this forum the way an operator would, one line each: the settings,
the host, the database and its schema, the readiness report, the outbox
worker, mail, the antivirus, the service files and timers, and the public
address. Under each problem it says what to change -- the variable, the
file -- and the command that fixes it, then how many things there are to
fix. It reads the environment file the service reads, so run it as the
service's user: sudo -u gpforum gpforum doctor.

  --upgrade   after an upgrade: the dependencies for this Perl, migrations
              still to apply, and service files that differ from this
              release's
  --json      one JSON object on stdout instead of sentences
  --help      show this help

docs/ops/doctor.md explains each line; docs/ops/upgrade.md is the upgrade.

Exit status: 0 nothing failed (warnings, marked !, are counted but do not
fail), 1 something failed, 2 usage error.
USAGE
}

1;

__END__

=head1 NAME

GPForum::Command::Doctor - Checks the forum, and says how to fix what is
wrong.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    # gpforum doctor
    # gpforum doctor --upgrade
    exit GPForum::Command::Doctor->new->run(@ARGV);

=head1 DESCRIPTION

C<gpforum doctor> runs L<GPForum::Service::Operations::Doctor> and writes
what it found as the walkthrough's target experience does: a check mark,
C<!> or a cross per line, C<Fix:> lines under each problem, and a closing
count, C<N things to fix>. When the settings cannot be used it lists every
problem with them and says the other checks wait for them. C<--json> gives
the same findings as one document.

=head1 SUBROUTINES/METHODS

=head2 run

Runs the command line. Returns 0 when nothing failed, 1 when something did,
and 2 on misuse.

=head2 usage_text

The text C<--help> prints.

=head1 DIAGNOSTICS

Every sentence is in the operator's language
(L<GPForum::Service::I18N::CliCatalog>). When the checks cannot be loaded
because a module the release needs is missing or built for another Perl,
that is the report, with the command that installs the modules
(L<GPForum::Service::Operations::Dependencies>). An error no check expected
is reported as every command reports a failure (L<GPForum::Command::Usage>).

=head1 CONFIGURATION AND ENVIRONMENT

The settings the front door loaded from the environment file.

=head1 DEPENDENCIES

L<GPForum::Service::Operations::Doctor>, L<GPForum::Command::Usage>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

See L<GPForum::Service::Operations::Doctor/BUGS AND LIMITATIONS>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
