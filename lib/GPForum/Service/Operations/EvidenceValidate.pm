# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::EvidenceValidate;

use Const::Fast;
use JSON::MaybeXS qw(decode_json encode_json);
use List::Util    qw(any);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File qw(path);

our $VERSION = '0.001';

const my $EXIT_FAILURE => 1;
const my @SECRET_KEY_RE => (
    qr/\A(?:smtp_)?password\z/msxi,
    qr/\A.*(?:secret|passwd|credential|authorization)\z/msxi,
);
const my @SECRET_VALUE_RE => (
    qr/smtp_password\s*=/msxi,               qr/super-secret/msxi,
    qr/BEGIN\s+(?:RSA\s+)?PRIVATE\s+KEY/msx, qr/mail-check-probe-token/msx,
);
const my @CLAIM_RE => (
    qr/PRIVATE\s+BETA\s*:\s*READY/msxi,
    qr/private_beta\s*=\s*ready/msxi,
    qr/private-beta\s+ready/msxi,
);

# The evidence types, in the order they are recognised: a check names its
# type, a drill names one of the three drills' types, and a staging drill is
# also known by its phases. Stress-load evidence is known by its mode or plan.
const my @CHECK_TYPES => qw(
  staging_host_verify mail_delivery evidence_validate staging_drill
  attachment_filesystem deploy_checklist staging_ops_extensions
  dead_letter_check mail_lifecycle_check
);
const my %DRILL_TYPE => map { $_ => 1 }
  qw(attachment_filesystem deploy_checklist staging_ops_extensions);
const my %STRESS_PROFILE => map { $_ => 1 } qw(smoke 100 500 1000);

# The types whose evidence reports a status, its redaction, its private-beta
# claim and its residual gaps.
const my %REPORTING_TYPE => map { $_ => 1 } qw(
  staging_host_verify mail_delivery stress_load staging_drill
  attachment_filesystem deploy_checklist staging_ops_extensions
  dead_letter_check mail_lifecycle_check
);
const my %STATUS => map { $_ => 1 } qw(pass ok degraded fail skipped dry-run);
const my %REDACTION_KEY => map { $_ => 1 } qw(secrets_redacted secrets_leaked);

has strict => 0;

sub run ( $self, $options ) {
    $options ||= {};
    my @paths  = @{ $options->{paths} // [] };
    my $strict = $options->{strict} ? 1 : 0;

    my $evidence = {
        status               => 'pass',
        check                => 'evidence_validate',
        strict               => $strict ? \1 : \0,
        files                => [],
        residual_gaps        => [],
        private_beta_claimed => 0,
        secrets_redacted     => \1,
    };

    if ( !@paths ) {
        $evidence->{status} = 'fail';
        $evidence->{error}  = 'pass one or more evidence JSON paths';
        push @{ $evidence->{residual_gaps} },
          'This validator does not claim private-beta readiness.';
        return $evidence;
    }

    my @findings;
    for my $path (@paths) {
        my $file = $self->_validate_file( $path, $strict );
        push @{ $evidence->{files} }, $file;
        push @findings,               @{ $file->{findings} // [] };
    }

    $evidence->{findings} = \@findings;
    $evidence->{status}   = _status_from_files( $evidence->{files} );
    push @{ $evidence->{residual_gaps} },
      'This validator does not claim private-beta readiness.',
'Passing validation only means archived JSON looks well-formed and free of obvious secrets — staging TLS / SMTP send / unit enable remain operator evidence.';

    return $evidence;
}

sub format_evidence ( $self, $evidence, $format ) {
    $format ||= 'json';
    return encode_json($evidence) . "\n" if $format eq 'json';

    return _human($evidence);
}

sub exit_status ( $, $evidence ) {
    my $status = $evidence->{status} // q{};
    return 0 if $status eq 'pass' || $status eq 'degraded';

    return $EXIT_FAILURE;
}

sub _validate_file ( $self, $path, $strict ) {
    my $result = {
        path     => $path,
        status   => 'pass',
        findings => [],
    };

    if ( !_has_text($path) || !-f $path ) {
        $result->{status} = 'fail';
        push @{ $result->{findings} },
          {
            severity => 'fail',
            code     => 'missing_file',
            message  => 'file missing'
          };
        return $result;
    }

    my $raw;
    try {
        $raw = path($path)->slurp;
    }
    catch ($error) {
        $result->{status} = 'fail';
        push @{ $result->{findings} },
          {
            severity => 'fail',
            code     => 'read_error',
            message  => _trim($error),
          };
        return $result;
    };

    my $decoded;
    try {
        $decoded = decode_json($raw);
    }
    catch ($error) {
        $decoded = undef;
    };
    if ( ref $decoded ne 'HASH' ) {
        $result->{status} = 'fail';
        push @{ $result->{findings} },
          {
            severity => 'fail',
            code     => 'invalid_json',
            message  => 'evidence must be a JSON object',
          };
        return $result;
    }

    $result->{detected_type} = _detect_type($decoded);
    push @{ $result->{findings} }, @{ _scan_secrets( $decoded, $raw ) };
    push @{ $result->{findings} }, @{ _scan_claims($raw) };
    push @{ $result->{findings} },
      @{ _type_rules( $result->{detected_type}, $decoded, $strict ) };

    $result->{status} = _status_from_findings( $result->{findings} );

    return $result;
}

sub _detect_type ($decoded) {
    my $check  = $decoded->{check} // q{};
    my $drill  = $decoded->{drill} // q{};
    my $phased = exists $decoded->{fresh_migrate}
      && exists $decoded->{upgrade_path};
    for my $type (@CHECK_TYPES) {
        return $type
          if $check eq $type
          || ( exists $DRILL_TYPE{$type} && $drill eq $type )
          || ( $type eq 'staging_drill'  && $phased );
    }
    return 'stress_load'
      if ( $decoded->{mode} // q{} ) eq 'stress-load'
      || exists $STRESS_PROFILE{ $decoded->{plan}{profile} // q{} };

    return 'unknown';
}

sub _type_rules ( $type, $decoded, $strict ) {
    my @findings;
    if ( exists $REPORTING_TYPE{$type} ) {
        push @findings, _require_status($decoded);
        push @findings,
          _require_true( $decoded, 'secrets_redacted', $strict, 'warn' );
        push @findings,
          _require_zero( $decoded, 'private_beta_claimed', $strict, 'warn' );
        push @findings,
          _require_array( $decoded, 'residual_gaps', $strict, 'warn' );
    }
    elsif ( $type eq 'evidence_validate' ) {
        push @findings, _require_status($decoded);
    }
    else {
        push @findings,
          {
            severity => $strict ? 'fail' : 'warn',
            code     => 'unknown_type',
            message  => 'could not classify evidence check/mode',
          };
    }

    return \@findings;
}

sub _require_status ($decoded) {
    my $status = $decoded->{status} // q{};
    return () if exists $STATUS{$status};

    return (
        {
            severity => 'fail',
            code     => 'missing_status',
            message  => 'status missing or unsupported',
        }
    );
}

sub _require_array ( $decoded, $key, $strict, $default_sev ) {
    my $value = $decoded->{$key};
    return () if ref $value eq 'ARRAY' && @{$value};

    return (
        {
            severity => $strict ? 'fail' : ( $default_sev // 'warn' ),
            code     => "missing_$key",
            message  => "$key missing or empty",
        }
    );
}

sub _require_true ( $decoded, $key, $strict, $default_sev ) {
    return () if _json_true( $decoded->{$key} );

    return (
        {
            severity => $strict ? 'fail' : ( $default_sev // 'warn' ),
            code     => "missing_$key",
            message  => "$key not true",
        }
    );
}

sub _require_zero ( $decoded, $key, $strict, $default_sev ) {
    my $value = $decoded->{$key};
    return () if defined $value && !ref $value && $value eq '0';
    return () if defined $value && !ref $value && $value == 0;

    return (
        {
            severity => $strict ? 'fail' : ( $default_sev // 'warn' ),
            code     => "bad_$key",
            message  =>
              "$key must be 0 / false when present for archive quality",
        }
    );
}

sub _scan_secrets ( $decoded, $raw ) {
    my @findings;
    push @findings, @{ _scan_secret_keys($decoded) };
    for my $re (@SECRET_VALUE_RE) {
        next if $raw !~ $re;
        push @findings,
          {
            severity => 'fail',
            code     => 'secret_pattern',
            message  => 'raw JSON matched a forbidden secret pattern',
          };
        last;
    }

    return \@findings;
}

sub _scan_secret_keys ( $value, $prefix = undef ) {
    $prefix //= q{};
    my @findings;
    if ( ref $value eq 'HASH' ) {
        for my $key ( keys %{$value} ) {
            my $path = $prefix eq q{} ? $key : "$prefix.$key";
            for my $re (@SECRET_KEY_RE) {
                if ( $key =~ $re
                    && !exists $REDACTION_KEY{$key} )
                {
                    push @findings,
                      {
                        severity => 'fail',
                        code     => 'secret_key',
                        message  => "forbidden key present: $path",
                      };
                }
            }
            push @findings, @{ _scan_secret_keys( $value->{$key}, $path ) };
        }
    }
    elsif ( ref $value eq 'ARRAY' ) {
        my $index = 0;
        for my $item ( @{$value} ) {
            push @findings,
              @{ _scan_secret_keys( $item, "$prefix\[$index\]" ) };
            $index++;
        }
    }

    return \@findings;
}

sub _scan_claims ($raw) {
    my @findings;
    for my $re (@CLAIM_RE) {
        next if $raw !~ $re;
        push @findings,
          {
            severity => 'fail',
            code     => 'private_beta_claim',
            message  => 'evidence appears to claim private-beta readiness',
          };
        last;
    }

    return \@findings;
}

sub _status_from_findings ($findings) {
    return 'fail'     if any { $_->{severity} eq 'fail' } @{$findings};
    return 'degraded' if any { $_->{severity} eq 'warn' } @{$findings};

    return 'pass';
}

sub _status_from_files ($files) {
    return 'fail'     if any { $_->{status} eq 'fail' } @{$files};
    return 'degraded' if any { $_->{status} eq 'degraded' } @{$files};

    return 'pass';
}

sub _human ($evidence) {
    my @lines = (
        'evidence-validate status=' . ( $evidence->{status} // 'fail' ),
        'files=' . scalar @{ $evidence->{files} // [] },
    );
    for my $file ( @{ $evidence->{files} // [] } ) {
        push @lines,
            'file path='
          . ( $file->{path} // q{} )
          . ' type='
          . ( $file->{detected_type} // 'unknown' )
          . ' status='
          . ( $file->{status} // 'fail' );
        for my $finding ( @{ $file->{findings} // [] } ) {
            push @lines, q{  } . join q{ },
              $finding->{severity} // 'fail',
              $finding->{code}     // 'unknown',
              $finding->{message}  // q{};
        }
    }

    return join( "\n", @lines ) . "\n";
}

sub _json_true ($value) {
    return 1 if $value;
    return 0;
}

sub _has_text ($value) {
    return defined $value && length $value;
}

sub _trim ($error) {
    $error = "$error";
    $error =~ s/\s+\z//msx;

    return $error;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::EvidenceValidate - Validate archived ops evidence JSON.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $report = GPForum::Service::Operations::EvidenceValidate->new->run(
        { paths => ['/tmp/staging-host-verify.json'], strict => 1 }
    );

=head1 DESCRIPTION

Non-destructive validator for operator evidence blobs. Checks JSON shape by
evidence family, rejects obvious secret material and private-beta readiness
claims, and optionally requires modern redaction markers with C<--strict>.
Never claims private-beta readiness.

=head1 SUBROUTINES/METHODS

=head2 run

Takes C<< { paths => \@paths, strict => $bool } >> and returns the evidence
hash reference: C<check> (C<evidence_validate>), C<status>, C<strict>,
C<files>, C<findings> (every file's, together), C<residual_gaps>,
C<private_beta_claimed> (0) and C<secrets_redacted> (true). With no paths it
returns C<status> C<fail> and an C<error> asking for them.

Each entry of C<files> holds C<path>, C<status>, C<detected_type> and
C<findings>, each finding a C<severity> (C<fail> or C<warn>), C<code> and
C<message>. A file that is missing (C<missing_file>), unreadable
(C<read_error>) or not a JSON object (C<invalid_json>) fails at once.
Otherwise the file fails on a forbidden key anywhere in it (C<secret_key>:
C<password>, C<smtp_password>, or a name ending in C<secret>, C<passwd>,
C<credential> or C<authorization>, other than C<secrets_redacted> and
C<secrets_leaked>), on raw text matching a secret pattern
(C<secret_pattern>), or on a private-beta readiness claim
(C<private_beta_claim>).

The type is read from C<check>, and failing that from C<drill>, C<mode>,
C<plan.profile> or the keys a staging drill writes. Every known family needs
a C<status> of C<pass>, C<ok>, C<degraded>, C<fail>, C<skipped> or
C<dry-run> (C<missing_status>, a failure). All but C<evidence_validate> also
need C<secrets_redacted> true, C<private_beta_claimed> 0 and a non-empty
C<residual_gaps>; each missing one is a warning, or a failure when strict. An
unclassified file is a warning, or a failure when strict.

A file, and then the whole run, is C<fail> with any failure, C<degraded>
with any warning, and C<pass> otherwise.

=head2 format_evidence

Takes the evidence and a format. C<json>, the default, returns one line of
JSON; anything else returns text: the status, the file count, and a line for
each file and each finding.

=head2 exit_status

Returns 0 when the status is C<pass> or C<degraded>, otherwise 1.

=head1 DIAGNOSTICS

None. A file that cannot be read or parsed is a finding, not an exception.

=head1 CONFIGURATION AND ENVIRONMENT

None. Strictness comes from C<run>'s options, which
L<GPForum::Command::EvidenceValidate> sets from C<--strict>.

=head1 DEPENDENCIES

L<JSON::MaybeXS>,
L<Mojo::File>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The secret and readiness checks match key names and raw text against fixed
patterns, so they find obvious material only. Passing means the archived
JSON is well-formed and free of obvious secrets; staging TLS, SMTP sends and
unit enablement remain operator evidence. The C<strict> attribute is not
read; only C<run>'s option is.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
