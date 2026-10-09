# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::AntivirusCheck;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::AntivirusCheck;

our $VERSION = '0.001';

const my %FORMAT_FOR => (
    '--json'  => 'json',
    '--human' => 'human',
);

has check => undef;    # optional: a test's double; else the real check

# Misuse -- an option this command does not know -- is the documented usage
# exit: the usage on stderr, status 2. The check reports as evidence what it
# anticipates, a misconfiguration and a scanner that does not answer included;
# an error it raises instead is a failure: 1 with its redacted reason on
# stderr and, under --json, the evidence's shape saying fail. It used to be
# rethrown with die, and an uncaught exception exits 255, or with whatever $!
# held: 2, misuse, after a failed file lookup.
sub run ( $self, @arguments ) {
    my $format = 'human';
    for my $argument (@arguments) {
        return GPForum::Command::Usage->help( \*STDOUT, _usage() )
          if $argument eq '--help';
        if ( !exists $FORMAT_FOR{$argument} ) {
            return GPForum::Command::Usage->error( "Unknown option: $argument",
                _usage() );
        }
        $format = $FORMAT_FOR{$argument};
    }

    my $status;
    try {
        $status = $self->_run($format);
    }
    catch ($error) {
        return GPForum::Command::Usage->failure( $error,
            $format eq 'json'
            ? ( \*STDOUT, { engine => 'unknown', problems => [] } )
            : () );
    };

    return $status;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

# Settings it cannot use stop the command before the check, as they stop
# every other (Command::Usage): reported inside the check, they read as "it
# does not scan uploads as it should", in English, and exited 1.
sub _run ( $self, $format ) {
    my $check = $self->check
      || GPForum::Service::Operations::AntivirusCheck->new(
        config => GPForum::Config->from_environment,
        host   => _host(),
      );
    my $evidence = $check->run;
    print $check->format_evidence( $evidence, $format )
      or croak 'failed to write antivirus-check evidence';

    return $check->exit_status($evidence);
}

# The host the findings' fixes are written for, naming the environment file
# the front door read, where the settings to correct are.
sub _host {
    my $file = GPForum::Command::Support::ServiceEnvironment->loaded;

    return GPForum::Service::Operations::Host->new(
        defined $file ? ( environment_file => $file ) : () );
}

sub _usage {
    return <<'USAGE';
Usage: bin/gpforum-antivirus-check [--human | --json]

Prove the upload antivirus works: report the scanner the configuration names
(GPFORUM_ANTIVIRUS), its signatures, and scan the EICAR test file -- which it
must detect -- and an ordinary file, which it must pass.

  --human    short plain-text evidence (default)
  --json     evidence as JSON
  --help     this text

Exit status: 0 ok, degraded or disabled; 1 the check failed; 2 misuse;
78 settings it cannot use.
USAGE
}

1;

__END__

=head1 NAME

GPForum::Command::AntivirusCheck - Command entry point for the antivirus check.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::Command::AntivirusCheck->new->run(@ARGV);

=head1 DESCRIPTION

Parses the options and runs L<GPForum::Service::Operations::AntivirusCheck>.

=head1 SUBROUTINES/METHODS

=head2 run

Runs the check and returns the exit status.

=head2 usage_text

The text C<--help> prints.

=head1 DIAGNOSTICS

An unknown option exits 2 with the usage on stderr. An error the check raises
instead of reporting exits 1 with its reason, redacted, on stderr; with
C<--json> the evidence also comes on stdout, C<status> C<fail>, the reason in
C<error> and no C<problems>. Settings it cannot use exit 78, every problem on
stderr in the operator's language, naming the environment file read.

=head1 CONFIGURATION AND ENVIRONMENT

The C<GPFORUM_ANTIVIRUS*> settings in L<GPForum::Config>.

=head1 DEPENDENCIES

L<GPForum::Service::Operations::AntivirusCheck>, L<GPForum::Command::Usage>.

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
