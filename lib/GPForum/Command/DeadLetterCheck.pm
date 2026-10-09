# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::DeadLetterCheck;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Command::Usage;
use GPForum::Service::Operations::DeadLetterCheck;
use GPForum::X::Usage;

our $VERSION = '0.001';

# Each flag sets one option to one value.
const my %FLAG_OPTIONS => (
    '--help'     => [ help   => 1 ],
    '--json'     => [ format => 'json' ],
    '--human'    => [ format => 'human' ],
    '--dry-run'  => [ mode   => 'dry_run' ],
    '--simulate' => [ mode   => 'simulate' ],
);

has check => undef;    # optional: a test's double; else the real check

# Misuse -- an option this command does not know, all its parser rejects --
# is the documented usage exit: the usage on stderr, status 2, without the
# " at bin/... line N." croak used to leave on it. A check that stops with an
# exception instead of evidence is a failure: 1 with its reason, redacted, on
# stderr and, as JSON, evidence saying fail (Command::Usage). It used to be
# rethrown with die, and an uncaught exception exits 255, or with whatever $!
# held: 2, misuse, after a failed file lookup.
sub run ( $self, @arguments ) {
    my $options;
    try {
        $options = _options(@arguments);
    }
    catch ($error) {
        return GPForum::Command::Usage->error( undef,
            GPForum::Command::Usage->trimmed($error) );
    };

    return _print_usage() if $options->{help};

    my $status;
    try {
        $status = $self->_run($options);
    }
    catch ($error) {
        return GPForum::Command::Usage->evidence_failure( $error,
            $options->{format},
            { check => 'dead_letter_check', mode => $options->{mode} } );
    };

    return $status;
}

sub _run ( $self, $options ) {
    my $service  = $self->_service;
    my $evidence = $service->run($options);
    print $service->format_evidence( $evidence, $options->{format} )
      or croak 'failed to write dead-letter-check evidence';

    return $service->exit_status($evidence);
}

sub _service ($self) {
    return $self->check if $self->check;

    return GPForum::Service::Operations::DeadLetterCheck->new;
}

sub _options (@arguments) {
    my %options = (
        format => 'json',
        mode   => 'simulate',
        help   => 0,
    );

    for my $argument (@arguments) {
        if ( !exists $FLAG_OPTIONS{$argument} ) {
            GPForum::X::Usage->throw(
                message => "Unknown option: $argument\n" . _usage() );
        }
        my ( $name, $value ) = @{ $FLAG_OPTIONS{$argument} };
        $options{$name} = $value;
    }

    return \%options;
}

sub _print_usage {
    return GPForum::Command::Usage->help( \*STDOUT, _usage() );
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return <<'USAGE';
Usage: bin/gpforum-dead-letter-check [options]

Automate the docs/ops/dead-letters.md staging check against an in-memory
outbox stack (simulate) or print the plan (dry-run). Emits EvidenceMeta JSON.
Does not claim private-beta readiness. Live staging PostgreSQL confirmation
remains a residual.

  --simulate  run permanent-failure -> dead-letter -> redispatch (default)
  --dry-run   print the staged plan only
  --json      evidence as JSON (default)
  --human     short plain-text evidence
  --help      show this help
USAGE
}

1;

__END__

=head1 NAME

GPForum::Command::DeadLetterCheck - Dead-letter staging check CLI.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::Command::DeadLetterCheck->new->run(@ARGV);

=head1 DESCRIPTION

Operator CLI for the dead-letter staging check harness.

=head1 SUBROUTINES/METHODS

=head2 check

The check to run; a test passes a double. Without one, a
L<GPForum::Service::Operations::DeadLetterCheck>.

=head2 run

Runs the command with its arguments; returns the exit status.

=head2 usage_text

The usage text, for the front door.

=head1 DIAGNOSTICS

Misuse exits 2 with the usage on standard error. An error the check raises
instead of reporting exits 1 with its reason, redacted, on standard error
and, with C<--json> (the default), evidence on standard output with
C<status> C<fail> and the reason in C<error>.

=head1 CONFIGURATION AND ENVIRONMENT

None: the check runs against an in-memory outbox stack and reads no
configuration.

=head1 DEPENDENCIES

L<GPForum::Service::Operations::DeadLetterCheck>,
L<GPForum::Command::Usage>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The simulation does not touch PostgreSQL: confirming the redispatch on a
live staging database remains an operator step.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
