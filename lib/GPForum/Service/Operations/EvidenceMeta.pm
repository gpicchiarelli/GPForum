package GPForum::Service::Operations::EvidenceMeta;

use strict;
use warnings;

use Const::Fast;
use Exporter qw(import);

our $VERSION = '0.001';

our @EXPORT_OK = qw(
  evidence_finalize
  evidence_unique_gaps
  evidence_scrub_structure
  evidence_scrub_text
);

const my $DEFAULT_BETA_GAP =>
  'This evidence does not claim private-beta readiness by itself.';

sub evidence_finalize {
    my ( $evidence, %options ) = @_;

    $evidence = { %{ $evidence // {} } };
    my $secrets = $options{secrets} // [];
    if ( @{$secrets} ) {
        $evidence = evidence_scrub_structure( $evidence, $secrets );
    }

    my @gaps = @{ $evidence->{residual_gaps} // [] };
    push @gaps, @{ $options{extra_gaps} // [] };
    if ( !grep { /private-beta [ ] readiness/msxi } @gaps ) {
        push @gaps, $DEFAULT_BETA_GAP;
    }

    $evidence->{secrets_redacted}     = \1;
    $evidence->{private_beta_claimed} = 0;
    $evidence->{residual_gaps}        = evidence_unique_gaps( \@gaps );

    return $evidence;
}

sub evidence_unique_gaps {
    my ($gaps) = @_;

    my %seen;
    my @unique;
    for my $gap ( @{ $gaps // [] } ) {
        next if !defined $gap || !length $gap;
        next if $seen{$gap}++;
        push @unique, $gap;
    }

    return \@unique;
}

sub evidence_scrub_structure {
    my ( $value, $secrets ) = @_;

    if ( ref $value eq 'HASH' ) {
        my %out;
        for my $key ( keys %{$value} ) {
            if ( $key =~ /password|secret|token|authorization|credential/msxi
                && $key ne 'secrets_redacted'
                && $key ne 'secrets_leaked'
                && $key ne 'username_configured' )
            {
                $out{$key} = '[redacted]';
                next;
            }
            $out{$key} = evidence_scrub_structure( $value->{$key}, $secrets );
        }
        return \%out;
    }
    if ( ref $value eq 'ARRAY' ) {
        return [ map { evidence_scrub_structure( $_, $secrets ) } @{$value} ];
    }
    if ( defined $value && !ref $value ) {
        return evidence_scrub_text( "$value", $secrets );
    }

    return $value;
}

sub evidence_scrub_text {
    my ( $text, $secrets ) = @_;

    for my $secret ( @{ $secrets // [] } ) {
        next if !defined $secret || !length $secret;
        my $quoted = quotemeta $secret;
        $text =~ s/$quoted/[redacted]/gmsx;
    }

    return $text;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::EvidenceMeta - Shared evidence metadata finalize.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use GPForum::Service::Operations::EvidenceMeta qw(evidence_finalize);

    my $report = evidence_finalize(
        { status => 'pass', residual_gaps => ['TLS still open'] },
        secrets => ['optional-secret'],
    );

=head1 DESCRIPTION

Applies the common ops-evidence contract used by mail-check, staging-host
verify, stress-load, and evidence-validate: C<secrets_redacted>,
C<private_beta_claimed=0>, deduplicated C<residual_gaps>, and optional secret
scrubbing. Never claims private-beta readiness.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
