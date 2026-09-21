package GPForum::Service::Operations::EvidenceValidate;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(decode_json encode_json);
use Mojo::Base -base;
use Mojo::File qw(path);

our $VERSION = '0.001';

const my $EXIT_FAILURE => 1;
const my @SECRET_KEY_RE => (
    qr/\A(?:smtp_)?password\z/msxi,
    qr/\A.*(?:secret|passwd|credential|authorization)\z/msxi,
);
const my @SECRET_VALUE_RE => (
    qr/smtp_password\s*=/msxi,
    qr/super-secret/msxi,
    qr/BEGIN\s+(?:RSA\s+)?PRIVATE\s+KEY/msx,
    qr/mail-check-probe-token/msx,
);
const my @CLAIM_RE => (
    qr/PRIVATE\s+BETA\s*:\s*READY/msxi,
    qr/private_beta\s*=\s*ready/msxi,
    qr/private-beta\s+ready/msxi,
);

has strict => 0;

sub run {
    my ( $self, $options ) = @_;

    $options ||= {};
    my @paths = @{ $options->{paths} // [] };
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
        push @findings, @{ $file->{findings} // [] };
    }

    $evidence->{findings} = \@findings;
    $evidence->{status}   = _status_from_files( $evidence->{files} );
    push @{ $evidence->{residual_gaps} },
      'This validator does not claim private-beta readiness.',
'Passing validation only means archived JSON looks well-formed and free of obvious secrets — staging TLS / SMTP send / unit enable remain operator evidence.';

    return $evidence;
}

sub format_evidence {
    my ( $self, $evidence, $format ) = @_;

    $format ||= 'json';
    return encode_json($evidence) . "\n" if $format eq 'json';

    return _human($evidence);
}

sub exit_status {
    my ( undef, $evidence ) = @_;

    my $status = $evidence->{status} // q{};
    return 0 if $status eq 'pass' || $status eq 'degraded';

    return $EXIT_FAILURE;
}

sub _validate_file {
    my ( $self, $path, $strict ) = @_;

    my $result = {
        path     => $path,
        status   => 'pass',
        findings => [],
    };

    if ( !_has_text($path) || !-f $path ) {
        $result->{status} = 'fail';
        push @{ $result->{findings} },
          { severity => 'fail', code => 'missing_file', message => 'file missing' };
        return $result;
    }

    my $raw = eval { return path($path)->slurp };
    if ($EVAL_ERROR) {
        $result->{status} = 'fail';
        push @{ $result->{findings} },
          {
            severity => 'fail',
            code     => 'read_error',
            message  => _trim($EVAL_ERROR),
          };
        return $result;
    }

    my $decoded = eval { return decode_json($raw) };
    if ( $EVAL_ERROR || ref $decoded ne 'HASH' ) {
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

sub _detect_type {
    my ($decoded) = @_;

    my $check = $decoded->{check} // q{};
    my $drill = $decoded->{drill} // q{};
    return 'staging_host_verify' if $check eq 'staging_host_verify';
    return 'mail_delivery'       if $check eq 'mail_delivery';
    return 'evidence_validate'   if $check eq 'evidence_validate';
    return 'staging_drill'
      if $check eq 'staging_drill'
      || ( exists $decoded->{fresh_migrate} && exists $decoded->{upgrade_path} );
    return 'attachment_filesystem'
      if $check eq 'attachment_filesystem'
      || $drill eq 'attachment_filesystem';
    return 'deploy_checklist'
      if $check eq 'deploy_checklist' || $drill eq 'deploy_checklist';
    return 'staging_ops_extensions'
      if $check eq 'staging_ops_extensions'
      || $drill eq 'staging_ops_extensions';
    return 'dead_letter_check' if $check eq 'dead_letter_check';
    return 'mail_lifecycle_check' if $check eq 'mail_lifecycle_check';
    return 'stress_load'
      if ( $decoded->{mode} // q{} ) eq 'stress-load'
      || ( $decoded->{plan}{profile} // q{} ) =~ /\A(?:smoke|100|500|1000)\z/msx;

    return 'unknown';
}

sub _type_rules {
    my ( $type, $decoded, $strict ) = @_;

    my @findings;
    if ( $type eq 'staging_host_verify'
        || $type eq 'mail_delivery'
        || $type eq 'stress_load'
        || $type eq 'staging_drill'
        || $type eq 'attachment_filesystem'
        || $type eq 'deploy_checklist'
        || $type eq 'staging_ops_extensions'
        || $type eq 'dead_letter_check'
        || $type eq 'mail_lifecycle_check' )
    {
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

sub _require_status {
    my ($decoded) = @_;

    my $status = $decoded->{status} // q{};
    return () if $status =~ /\A(?:pass|ok|degraded|fail|skipped|dry-run)\z/msx;

    return (
        {
            severity => 'fail',
            code     => 'missing_status',
            message  => 'status missing or unsupported',
        }
    );
}

sub _require_array {
    my ( $decoded, $key, $strict, $default_sev ) = @_;

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

sub _require_true {
    my ( $decoded, $key, $strict, $default_sev ) = @_;

    return () if _json_true( $decoded->{$key} );

    return (
        {
            severity => $strict ? 'fail' : ( $default_sev // 'warn' ),
            code     => "missing_$key",
            message  => "$key not true",
        }
    );
}

sub _require_zero {
    my ( $decoded, $key, $strict, $default_sev ) = @_;

    my $value = $decoded->{$key};
    return () if defined $value && !ref $value && $value eq '0';
    return () if defined $value && !ref $value && $value == 0;

    return (
        {
            severity => $strict ? 'fail' : ( $default_sev // 'warn' ),
            code     => "bad_$key",
            message  => "$key must be 0 / false when present for archive quality",
        }
    );
}

sub _scan_secrets {
    my ( $decoded, $raw ) = @_;

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

sub _scan_secret_keys {
    my ( $value, $prefix ) = @_;

    $prefix //= q{};
    my @findings;
    if ( ref $value eq 'HASH' ) {
        for my $key ( keys %{$value} ) {
            my $path = $prefix eq q{} ? $key : "$prefix.$key";
            for my $re (@SECRET_KEY_RE) {
                if ( $key =~ $re
                    && $key !~ /\A(?:secrets_redacted|secrets_leaked)\z/msx )
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
            push @findings, @{ _scan_secret_keys( $item, "$prefix\[$index\]" ) };
            $index++;
        }
    }

    return \@findings;
}

sub _scan_claims {
    my ($raw) = @_;

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

sub _status_from_findings {
    my ($findings) = @_;

    return 'fail' if grep { $_->{severity} eq 'fail' } @{$findings};
    return 'degraded'
      if grep { $_->{severity} eq 'warn' } @{$findings};

    return 'pass';
}

sub _status_from_files {
    my ($files) = @_;

    return 'fail' if grep { $_->{status} eq 'fail' } @{$files};
    return 'degraded'
      if grep { $_->{status} eq 'degraded' } @{$files};

    return 'pass';
}

sub _human {
    my ($evidence) = @_;

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
            push @lines,
                '  '
              . ( $finding->{severity} // 'fail' ) . ' '
              . ( $finding->{code} // 'unknown' ) . ' '
              . ( $finding->{message} // q{} );
        }
    }

    return join( "\n", @lines ) . "\n";
}

sub _json_true {
    my ($value) = @_;

    return 1 if $value;
    return 0;
}

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value;
}

sub _trim {
    my ($error) = @_;

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

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
