# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::AntivirusCheck;

use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::Util qw(encode);

use GPForum::Config;
use GPForum::Infrastructure::Antivirus;
use GPForum::Service::Attachment::Validator;
use GPForum::Service::Clock;
use GPForum::Service::Operations::Findings;
use GPForum::Service::Operations::Host;

our $VERSION = '0.001';

has clock   => sub { return GPForum::Service::Clock->new; };
has host    => sub { return GPForum::Service::Operations::Host->new; };
has config  => sub { return GPForum::Config->from_environment; };
has scanner => sub ($self) {
    return GPForum::Infrastructure::Antivirus->from_config( $self->config );
};

# EICAR: the harmless file every antivirus is built to report, so detecting it
# proves the scanner scans, not merely that it answers. Kept in two pieces so
# that this module, as it sits on disk, is not itself what gets detected.
sub test_file ($class) {
    return 'X5O!P%@AP[4\PZX54(P^)7CC)7}$'
      . 'EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*';
}

# Readiness asks whether the antivirus answers. This asks whether it works:
# the test file must be found and an ordinary file must pass. ADR 0108.
sub run ($self) {
    my $config;
    try {
        $config = $self->config;
    }
    catch ($error) {
        return {
            status   => 'fail',
            engine   => 'unknown',
            problems => [ _trimmed($error) ]
        };
    };

    my $engine = $config->antivirus;
    if ( $engine eq 'none' ) {
        return {
            status      => 'disabled',
            engine      => $engine,
            environment => $config->environment,
            detail      => _disabled_detail(),
        };
    }

    my $scanner;
    try {
        $scanner = $self->scanner;
    }
    catch ($error) {
        return {
            status   => 'fail',
            engine   => $engine,
            problems => [ _trimmed($error) ]
        };
    };

    return $self->_exercise( $engine, $scanner );
}

# Run from a login shell, the check sees that shell's environment, not the
# service's: without GPFORUM_ENV it is development, where scanning is off by
# default, and "disabled" would say nothing about the clamd production uses.
sub _disabled_detail {
    my $detail = 'scanning is off: uploads are checked for format only';
    return $detail if exists $ENV{GPFORUM_ENV};

    return
        "$detail. GPFORUM_ENV is not set in this shell, so this is the"
      . q{ development default; run the check with the service's environment}
      . ' (docs/ops/antivirus.md)';
}

sub format_evidence ( $self, $evidence, $format ) {
    return encode_json($evidence) . "\n" if ( $format // 'json' ) ne 'human';

    return encode( 'UTF-8', $self->findings($evidence)->human_text );
}

# What the check found, as an operator reads it: the scanner that works,
# or why it does not and what to do about it. A clamd that does not answer
# was reported once per scan -- eight times -- and never said to install it,
# start it, or turn scanning off.
sub findings ( $self, $evidence, $findings = undef ) {
    $findings //= GPForum::Service::Operations::Findings->new(
        catalog => $self->host->catalog );
    my $status = $evidence->{status} // 'fail';
    my $health = $evidence->{health} // {};

    if ( $status eq 'disabled' ) {
        my $deployed = $self->host->is_deployed;
        return $findings->add(
            name    => 'antivirus',
            status  => $deployed ? 'degraded' : 'ok',
            message => ['antivirus.off'],
            fixes   => $deployed ? $self->_enable_fixes : [],
        );
    }
    if ( my $socket = _unreachable($evidence) ) {
        return $findings->add(
            name    => 'antivirus',
            status  => 'fail',
            message => [ 'antivirus.unreachable', { socket => $socket } ],
            notes => [ [ 'antivirus.detail', { detail => _reason($health) } ] ],
            fixes => [ @{ $self->_install_fixes }, $self->_none_fix ],
        );
    }
    if ( $status eq 'ok' || $status eq 'degraded' ) {
        return $findings->add(
            name    => 'antivirus',
            status  => $status,
            message => [
                'antivirus.works',
                { engine => $health->{engine} // $evidence->{engine} }
            ],
            notes => $status eq 'ok'
            ? []
            : [ [ 'antivirus.detail', { detail => $health->{error} // q{} } ] ],
            fixes => $status eq 'ok' ? [] : $self->_signature_fixes,
        );
    }

    return $findings->add(
        name    => 'antivirus',
        status  => 'fail',
        message => ['antivirus.broken'],
        notes   => [
            map { [ 'antivirus.detail', { detail => $_ } ] }
              @{ $evidence->{problems} // [] }
        ],
    );
}

# The socket of a clamd that did not answer, else undef.
sub _unreachable ($evidence) {
    my $health = $evidence->{health} // {};
    my $error  = $health->{error} // ( $evidence->{test_file} // {} )->{error}
      // q{};
    return undef if $error !~ /cannot [ ] connect [ ] to [ ] clamd/msx;

    return $health->{socket} // 'clamd';
}

# What the operating system said, without the sentence around it.
sub _reason ($health) {
    my $error = $health->{error} // q{};
    my ($reason) =
      $error =~
      /cannot [ ] connect [ ] to [ ] clamd [ ] at [ ] .+ : [ ] (.+) \z/msx;

    return $reason // $error;
}

# Install clamd, or start the one installed: its daemon waits for
# freshclam's first download of the signatures before it listens.
sub _install_fixes ($self) {
    my $packaging = $self->host->os->antivirus_packaging;
    my @fixes;
    if ( my $install = $self->host->antivirus_install ) {
        push @fixes, $install;
    }
    if ( @{ $packaging->{services} // [] } ) {
        push @fixes,
          [
            'antivirus.fix_start',
            { command => $self->host->package_start_command($packaging) }
          ];
    }

    return \@fixes;
}

# Scanning turned off where it should be on: install clamd, then name it.
sub _enable_fixes ($self) {
    my @fixes;
    if ( my $install = $self->host->antivirus_install ) {
        push @fixes, $install;
    }

    return [ @fixes,
        [ 'antivirus.fix_clamd', { where => $self->host->where } ] ];
}

sub _none_fix ($self) {
    return [ 'antivirus.fix_none', { where => $self->host->where } ];
}

sub _signature_fixes ($self) {
    my $packaging = $self->host->os->antivirus_packaging;
    my $updater   = $packaging->{services}[1];
    return [] if !defined $updater;

    return [
        [
            'antivirus.fix_signatures',
            {
                command => $self->host->package_start_command(
                    { %{$packaging}, services => [$updater] }
                )
            }
        ]
    ];
}

sub exit_status ( $, $evidence ) {
    return $evidence->{status} eq 'fail' ? 1 : 0;
}

sub _exercise ( $self, $engine, $scanner ) {
    my $health = $scanner->health( $self->clock->now_epoch );
    my $found  = $scanner->scan( $self->test_file );
    my $passed = $scanner->scan("GPForum antivirus check: an ordinary file.\n");
    my $largest =
      $scanner->scan(
        'x' x GPForum::Service::Attachment::Validator->max_bytes );

    my @problems;
    if ( $found->{status} ne 'infected' ) {
        push @problems,
          'the EICAR test file was not detected: ' . _describe($found);
    }
    if ( $passed->{status} ne 'clean' ) {
        push @problems, 'an ordinary file did not pass: ' . _describe($passed);
    }
    if ( $largest->{status} ne 'clean' ) {
        push @problems,
            'a file as large as the upload limit was not scanned: '
          . _describe($largest)
          . ' -- is clamd\'s StreamMaxLength at least 26M?';
    }

    return {
        status        => _status( $health, \@problems ),
        engine        => $engine,
        health        => $health,
        test_file     => $found,
        ordinary_file => $passed,
        largest_file  => $largest,
        problems      => \@problems,
    };
}

sub _status ( $health, $problems ) {
    return 'fail'     if @{$problems};
    return 'degraded' if $health->{status} ne 'ok';

    return 'ok';
}

sub _describe ($verdict) {
    return $verdict->{status}
      . ( $verdict->{error} ? " ($verdict->{error})" : q{} );
}

sub _trimmed ($message) {
    my $text = defined $message ? "$message" : 'unknown failure';
    $text =~ s/\s+ at \s+ \S+ \s+ line \s+ \d+ [.]? \s* \z//msx;

    return $text;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::AntivirusCheck - Prove the upload antivirus works.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $check    = GPForum::Service::Operations::AntivirusCheck->new;
    my $evidence = $check->run;
    print $check->format_evidence( $evidence, 'human' );

=head1 DESCRIPTION

Builds the scanner the configuration names (ADR 0108), reports its health,
and scans three files: the EICAR test file, which it must detect, an ordinary
file, which it must pass, and a file as large as the upload limit, which it
must also pass -- a StreamMaxLength below it would leave large uploads
unscanned. Readiness only asks whether the scanner
answers; this asks whether it scans.

=head1 SUBROUTINES/METHODS

=head2 run

Returns the evidence: C<status> C<ok>, C<degraded> (it works, but its health
is not ok -- for example old signatures), C<fail> or C<disabled>.

=head2 test_file

The EICAR test string.

=head2 format_evidence

The evidence as JSON, or for C<human> its L</findings> as the lines an
operator reads.

=head2 findings

Takes the evidence and, optionally, a
L<GPForum::Service::Operations::Findings> to add to, and adds one finding,
C<antivirus>, in the operator's language: the engine that works; or a clamd
that does not answer, once, with the commands that install it and start it
on this host and the setting that turns scanning off; or old signatures,
with the command that starts freshclam; or what else failed. Scanning off is
fine in development and a warning once deployed. Returns the findings.

=head2 host

The L<GPForum::Service::Operations::Host> whose packages, services and
settings file the fixes name.

=head2 exit_status

1 when the check failed, otherwise 0.

=head1 DIAGNOSTICS

Every problem found is listed under C<problems>.

=head1 CONFIGURATION AND ENVIRONMENT

The C<GPFORUM_ANTIVIRUS*> settings in L<GPForum::Config>.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::Antivirus>, L<GPForum::Config>, L<JSON::MaybeXS>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

It proves the scanner detects a known test file, not that it detects every
threat; no antivirus does.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
