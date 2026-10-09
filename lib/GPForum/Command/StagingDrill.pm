# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::StagingDrill;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Command::Usage;
use GPForum::Command::PerformanceSeed;
use GPForum::Service::Operations::StagingDrill;
use GPForum::X::Usage;

our $VERSION = '0.001';

const my $DEFAULT_SEED_PROFILE => 'small';
const my %SEED_PROFILES => map { $_ => 1 } qw(small medium hot-thread none);

# Each flag sets one option to one value.
const my %FLAG_OPTIONS => (
    '--help'              => [ help              => 1 ],
    '--json'              => [ format            => 'json' ],
    '--human'             => [ format            => 'human' ],
    '--skip-upgrade'      => [ skip_upgrade      => 1 ],
    '--skip-dump-restore' => [ skip_dump_restore => 1 ],
    '--keep-databases'    => [ keep_databases    => 1 ],
);
const my %VALUE_OPTIONS => (
    '--database'     => 'database_prefix',
    '--seed-profile' => 'seed_profile',
);

has drill => undef;    # optional: a test's double; else the real drill

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
            $options->{format}, { check => 'staging_drill' } );
    };

    return $status;
}

sub _run ( $self, $options ) {
    my $service  = $self->_service;
    my $evidence = $service->run($options);
    print $service->format_evidence( $evidence, $options->{format} )
      or croak 'failed to write staging drill evidence';

    return $service->exit_status($evidence);
}

sub _service ($self) {
    return $self->drill if $self->drill;

    return GPForum::Service::Operations::StagingDrill->new(
        seed => sub ($profile) {
            return GPForum::Command::PerformanceSeed->new->run( '--profile',
                $profile );
        },
    );
}

sub _options (@arguments) {
    my %options = (
        format            => 'json',
        seed_profile      => $DEFAULT_SEED_PROFILE,
        skip_upgrade      => 0,
        skip_dump_restore => 0,
        keep_databases    => 0,
        help              => 0,
        database_prefix   => undef,
    );

    while (@arguments) {
        my $argument = shift @arguments;
        if ( exists $FLAG_OPTIONS{$argument} ) {
            my ( $name, $value ) = @{ $FLAG_OPTIONS{$argument} };
            $options{$name} = $value;
            next;
        }
        if ( !exists $VALUE_OPTIONS{$argument} ) {
            GPForum::X::Usage->throw(
                message => "Unknown option: $argument\n" . _usage() );
        }

        my $value = shift @arguments;
        if ( !_has_text($value) || substr( $value, 0, 1 ) eq q{-} ) {
            GPForum::X::Usage->throw( message => _usage() );
        }
        if ( $argument eq '--seed-profile' && !exists $SEED_PROFILES{$value} ) {
            GPForum::X::Usage->throw(
                message => "Unsupported seed profile: $value\n" . _usage() );
        }
        $options{ $VALUE_OPTIONS{$argument} } = $value;
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
Usage: bin/gpforum-staging-drill [options]

Requires GPFORUM_DATABASE_DSN (and user/password env as for other tools).
Creates throwaway databases, migrates, optionally seeds, dumps/restores,
prints evidence, then drops throwaways.

  --json                 evidence as JSON (default)
  --human                short plain-text evidence
  --database PREFIX      throwaway name prefix (default gpforum_drill_<pid>_<time>)
  --seed-profile NAME    small|medium|hot-thread|none (default small)
  --skip-upgrade         skip upgrade-from-previous migration path
  --skip-dump-restore    skip pg_dump/pg_restore round-trip
  --keep-databases       leave throwaway databases after the run
  --help                 show this help

Attachment blobs under var/attachments are not covered by dump/restore;
use script/staging-drill-attachments for throwaway filesystem restore and
static nginx/systemd template checks.
USAGE
}

sub _has_text ($value) {
    return defined $value && length $value;
}

1;

__END__

=head1 NAME

GPForum::Command::StagingDrill - Operator CLI for migrate/dump/restore drills.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::Command::StagingDrill->new->run(@ARGV);

=head1 DESCRIPTION

Thin command entry point for L<GPForum::Service::Operations::StagingDrill>.

=head1 SUBROUTINES/METHODS

=head2 run

Parses options, runs the drill, prints evidence, and returns an exit status.

=head1 DIAGNOSTICS

Unknown options and unsupported seed profiles exit 2 with the usage on
standard error. Missing database environment or drill failures produce
non-zero exit status after evidence is printed. An error the drill raises
instead of reporting exits 1 with its reason, redacted, on standard error
and, with C<--json> (the default), evidence on standard output with
C<status> C<fail> and the reason in C<error>.

=head1 CONFIGURATION AND ENVIRONMENT

See L<GPForum::Service::Operations::StagingDrill>.

=head1 DEPENDENCIES

L<GPForum::Service::Operations::StagingDrill>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not rehearse full nginx/systemd deployment.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
