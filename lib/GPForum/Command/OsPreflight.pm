# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::OsPreflight;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS ();
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::Util qw(encode);

use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Support::Words;
use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Config::Report;
use GPForum::OS::Preflight;
use GPForum::Runtime;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::OSPreflight;
use GPForum::X::Config;
use GPForum::X::Usage;

our $VERSION = '0.001';

# Each flag sets one option to one value.
const my %FLAG_OPTIONS => (
    '--help'   => [ help   => 1 ],
    '-h'       => [ help   => 1 ],
    '--json'   => [ json   => 1 ],
    '--human'  => [ json   => 0 ],
    '--strict' => [ strict => 1 ],
);

# What the service files put in front of each line they write to the
# journal, so `journalctl -u gpforum` says which program spoke.
const my $JOURNAL_PREFIX => 'os-preflight: ';

has config  => undef;    # optional: read from the environment otherwise
has runtime => undef;    # optional: built from the configuration otherwise
has catalog => sub { return GPForum::Service::I18N::CliCatalog->new; };

# Misuse -- an option this command does not know, all its parser rejects --
# is the documented usage exit: the usage on stderr, status 2. A check that
# cannot start -- a setting that does not parse -- exits 78, EX_CONFIG, as
# every command does, and under --json is still a document.
sub run ( $self, @arguments ) {
    my $options;
    try {
        $options = _options(@arguments);
    }
    catch ($error) {
        return GPForum::Command::Usage->error( undef,
            GPForum::Command::Usage->trimmed($error) );
    };

    return GPForum::Command::Usage->help( \*STDOUT, _usage() )
      if $options->{help};

    my $status;
    try {
        $status = $self->_run($options);
    }
    catch ($error) {
        return $self->_settings_failure( $error, $options )
          if GPForum::X::Config->caught($error);
        return GPForum::Command::Usage->failure( $error,
            $options->{json} ? ( \*STDOUT, { checks => [] } ) : () );
    };

    return $status;
}

sub _run ( $self, $options ) {
    my $file    = GPForum::Command::Support::ServiceEnvironment->loaded;
    my $service = GPForum::Service::Operations::OSPreflight->new(
        host => GPForum::Service::Operations::Host->new(
            catalog => $self->catalog,
            defined $file ? ( environment_file => $file ) : (),
        )
    );
    my $report   = $self->_preflight->report;
    my $findings = $service->findings($report);

    my $output =
      $options->{json}
      ? JSON::MaybeXS->new( canonical => 1 )->encode($report) . "\n"
      : $findings->human_text;
    print encode( 'UTF-8', $output )
      or croak 'failed to write OS preflight report';

    # Under --strict -- what the service files run before a start -- the
    # report on stdout is JSON, for the journal to keep; each problem is
    # also written to stderr in the operator's words, so `journalctl -u
    # gpforum` shows what to fix without reading the JSON.
    if ( $options->{strict} && $options->{json} ) {
        for my $line ( @{ $findings->problem_lines($JOURNAL_PREFIX) } ) {
            print {*STDERR} encode( 'UTF-8', "$line\n" )
              or croak 'failed to write OS preflight problem';
        }
    }

    return _exit_status($report);
}

# Settings that do not parse stop the check before it looks at the host.
# The report goes to stderr once, in the operator's language, ending with the
# environment file this process read, and the status is 78. Under --json
# the document on stdout says fail with the problems' sentences in English
# as its error and the variables they name, not the report a second and a
# third time: the service files send both streams to the journal.
sub _settings_failure ( $self, $error, $options ) {
    my $invalid  = GPForum::X::Config->caught($error);
    my @problems = @{ $invalid->problems };
    if ( !@problems ) {
        return GPForum::Command::Usage->failure( $error,
            $options->{json} ? ( \*STDOUT, { checks => [] } ) : () );
    }

    print {*STDERR} encode(
        'UTF-8',
        GPForum::Command::Support::Words->new( catalog => $self->catalog )
          ->config_report(
            \@problems, GPForum::Command::Support::ServiceEnvironment->loaded
          )
    ) or croak 'failed to write the settings report';
    if ( $options->{json} ) {
        GPForum::Command::Usage->json(
            \*STDOUT,
            {
                status => 'fail',
                checks => [],
                error  => join( q{ },
                    map { GPForum::Config::Report->sentence($_) } @problems ),
                variables => [ map { $_->{variable} } @problems ],
            }
        );
    }

    return $GPForum::Command::Usage::EXIT_CONFIG;
}

sub _preflight ($self) {
    my $config  = $self->config  || GPForum::Config->from_environment;
    my $runtime = $self->runtime || GPForum::Runtime->from_config($config);

    return GPForum::OS::Preflight->from_runtime(
        $runtime,
        min_recommended_workers   => $config->os_min_recommended_workers,
        max_open_file_descriptors => $config->os_max_open_file_descriptors,
    );
}

sub _options (@arguments) {
    my %options = (
        help   => 0,
        json   => 0,
        strict => 0,
    );

    for my $argument (@arguments) {
        if ( !exists $FLAG_OPTIONS{$argument} ) {
            GPForum::X::Usage->throw(
                message => "Unknown option: $argument\n\n" . _usage() );
        }
        my ( $name, $value ) = @{ $FLAG_OPTIONS{$argument} };
        $options{$name} = $value;
    }

    return \%options;
}

# A check that fails stops a start; a degraded one does not (owner decision
# D10, 2026-10-07). --strict used to fail on degraded too, and every 1-vCPU
# host has a recommended worker count below the default threshold, so the
# shipped units refused to start there at all.
sub _exit_status ($report) {
    return $report->{status} eq 'fail' ? 1 : 0;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    my $program = GPForum::Command::Usage->program;

    return <<"USAGE";
Usage: $program [--json] [--strict]

Say whether this host can run GPForum: its operating system and CPUs, the
web processes it is given, the open-file limit, swap, and the features the
settings ask of the operating system. Each problem comes with what to
change.

  --json     the whole report as one JSON object
  --strict   what the service files run before a start: with --json, also
             write each problem to stderr for the journal
  --human    the lines an operator reads (the default)
  --help     this text

Exit status: 0 the host can run GPForum, warnings included; 1 it cannot;
2 misuse; 78 settings it cannot use.
USAGE
}

1;

__END__

=head1 NAME

GPForum::Command::OsPreflight - Say whether this host can run GPForum.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::Command::OsPreflight->new->run(@ARGV);

=head1 DESCRIPTION

The command behind C<gpforum os-preflight> and C<script/os-preflight>. It
reads the host through L<GPForum::OS::Preflight> and writes what it found
through L<GPForum::Service::Operations::OSPreflight/findings>, in the
operator's language, or the whole report as JSON.

=head1 SUBROUTINES/METHODS

=head2 config

The L<GPForum::Config> whose thresholds apply; read from the environment
otherwise.

=head2 runtime

The L<GPForum::Runtime> to judge; built from the configuration otherwise.

=head2 catalog

The L<GPForum::Service::I18N::CliCatalog> the lines are written from.

=head2 run

Runs the command with its arguments; returns the exit status.

=head2 usage_text

The usage text, for the front door.

=head1 DIAGNOSTICS

Misuse exits 2 with the usage on standard error. Settings that do not parse
exit 78 with the settings report on standard error, once, naming the
environment file read, and under C<--json> a document saying C<fail>.

=head1 CONFIGURATION AND ENVIRONMENT

C<GPFORUM_OS_MIN_RECOMMENDED_WORKERS>, C<GPFORUM_OS_MAX_OPEN_FILE_DESCRIPTORS>,
C<GPFORUM_WEB_PROCESSES> and the other settings L<GPForum::Runtime> reads;
C<LC_ALL>, C<LC_MESSAGES> and C<LANG> for the language.

=head1 DEPENDENCIES

L<GPForum::OS::Preflight>, L<GPForum::Service::Operations::OSPreflight>,
L<GPForum::Service::Operations::Findings>, L<GPForum::Command::Usage>.

=head1 INCOMPATIBILITIES

The human form is no longer C<key=value> lines; scripts read C<--json>.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
