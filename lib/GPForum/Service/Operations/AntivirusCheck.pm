# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::AntivirusCheck;

use strict;
use warnings;

use English       qw(-no_match_vars);
use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base, -signatures;

use GPForum::Config;
use GPForum::Infrastructure::Antivirus;
use GPForum::Service::Attachment::Validator;
use GPForum::Service::Clock;

our $VERSION = '0.001';

has clock   => sub { return GPForum::Service::Clock->new; };
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
    my $config = eval { return $self->config; };
    if ( !$config ) {
        return {
            status   => 'fail',
            engine   => 'unknown',
            problems => [ _trimmed($EVAL_ERROR) ]
        };
    }

    my $engine = $config->antivirus;
    if ( $engine eq 'none' ) {
        return {
            status      => 'disabled',
            engine      => $engine,
            environment => $config->environment,
            detail      => _disabled_detail(),
        };
    }

    my $scanner = eval { return $self->scanner; };
    if ( !$scanner ) {
        return {
            status   => 'fail',
            engine   => $engine,
            problems => [ _trimmed($EVAL_ERROR) ]
        };
    }

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

    return join( "\n", _human_lines($evidence) ) . "\n";
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

sub _human_lines ($evidence) {
    my @lines =
      ("antivirus-check status=$evidence->{status} engine=$evidence->{engine}");
    if ( $evidence->{detail} ) {
        push @lines, "  $evidence->{detail}";
    }

    my $health = $evidence->{health} || {};
    for my $field (qw(socket program engine database published)) {
        if ( $health->{$field} ) {
            push @lines, "  $field: $health->{$field}";
        }
    }
    if ( $health->{status} ) {
        push @lines, '  health: ' . _describe($health);
    }
    if ( my $found = $evidence->{test_file} ) {
        push @lines,
            '  EICAR test file: '
          . _describe($found)
          . ( $found->{signature} ? " ($found->{signature})" : q{} );
    }
    if ( my $passed = $evidence->{ordinary_file} ) {
        push @lines, '  ordinary file: ' . _describe($passed);
    }
    if ( my $largest = $evidence->{largest_file} ) {
        push @lines, '  file at the upload limit: ' . _describe($largest);
    }
    push @lines, map { "  problem: $_" } @{ $evidence->{problems} || [] };

    return @lines;
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

The evidence as JSON, or as short lines for C<human>.

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
