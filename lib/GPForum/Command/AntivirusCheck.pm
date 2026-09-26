# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::AntivirusCheck;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

use GPForum::Command::Usage;
use GPForum::Service::Operations::AntivirusCheck;

our $VERSION = '0.001';

const my %FORMAT_FOR => (
    '--json'  => 'json',
    '--human' => 'human',
);

has check => undef;

# A usage croak becomes the documented usage exit instead of an uncaught
# exception: same text, on stderr, status 2, without croak's " at FILE line N".
# Anything else is rethrown, so a real failure is not relabelled as misuse.
sub run ( $self, @arguments ) {
    my $status = eval { return $self->_run(@arguments); };
    return $status if defined $status;

    my $error = GPForum::Command::Usage->trimmed($EVAL_ERROR);
    if ( !GPForum::Command::Usage->is_usage($error) ) {
        die "$error\n";
    }

    return GPForum::Command::Usage->error( undef, $error );
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _run ( $self, @arguments ) {
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

    my $check =
      $self->check || GPForum::Service::Operations::AntivirusCheck->new;
    my $evidence = $check->run;
    print $check->format_evidence( $evidence, $format )
      or croak 'failed to write antivirus-check evidence';

    return $check->exit_status($evidence);
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

Exit status: 0 ok, degraded or disabled; 1 the check failed; 2 misuse.
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

An unknown option exits 2 with the usage on stderr.

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
