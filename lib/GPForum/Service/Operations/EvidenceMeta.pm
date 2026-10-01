# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::EvidenceMeta;

use strict;
use warnings;
use feature 'signatures';

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

sub evidence_finalize ( $evidence, %options ) {
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

sub evidence_unique_gaps ($gaps) {
    my %seen;
    my @unique;
    for my $gap ( @{ $gaps // [] } ) {
        next if !defined $gap || !length $gap;
        next if $seen{$gap}++;
        push @unique, $gap;
    }

    return \@unique;
}

sub evidence_scrub_structure ( $value, $secrets ) {
    if ( ref $value eq 'HASH' ) {
        my %out;
        for my $key ( keys %{$value} ) {
            if (   $key =~ /password|secret|token|authorization|credential/msxi
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

sub evidence_scrub_text ( $text, $secrets ) {
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
verify, stress-load, staging drills, and evidence-validate: C<secrets_redacted>,
C<private_beta_claimed=0>, deduplicated C<residual_gaps>, and optional secret
scrubbing. Never claims private-beta readiness.

The four functions are exported on request only.

=head1 SUBROUTINES/METHODS

=head2 evidence_finalize

Takes an evidence hash reference (or undef) and the options C<secrets>
(an array reference of strings to scrub) and C<extra_gaps> (an array
reference of residual gaps to add). Returns a new hash reference: the
evidence scrubbed with C<evidence_scrub_structure> when there are
secrets, else a shallow copy, with C<residual_gaps> set to its own gaps
followed by the extra ones, the default private-beta gap appended when no
gap mentions private-beta readiness, duplicates and empty entries
dropped; C<private_beta_claimed> set to 0; and C<secrets_redacted> set to
a JSON true (C<\1>), whether or not anything was scrubbed.

=head2 evidence_unique_gaps

Takes an array reference of gaps (or undef). Returns a new array
reference of its defined, non-empty entries, each once, in the order they
first appear.

=head2 evidence_scrub_structure

Takes a value and an array reference of secrets. Returns a copy of the
value: a hash with every key whose name mentions a password, secret,
token, authorization or credential (case-insensitively, except
C<secrets_redacted>, C<secrets_leaked> and C<username_configured>) set to
C<[redacted]> and every other value scrubbed in turn; an array with each
element scrubbed; a plain scalar through C<evidence_scrub_text>; and any
other reference, including an object, as it is.

=head2 evidence_scrub_text

Takes a string and an array reference of secrets (or undef). Returns the
string with every occurrence of each non-empty secret, matched literally,
replaced by C<[redacted]>.

=head1 DIAGNOSTICS

None. The functions do not die on missing input: an undef evidence, gap
list or secret list counts as empty.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<Exporter>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Without secrets, C<evidence_finalize> copies only the top level: nested
hashes and arrays are shared with the caller's evidence, and no key is
redacted by name.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
