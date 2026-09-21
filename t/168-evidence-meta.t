package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';

use GPForum::Service::Operations::EvidenceMeta qw(
  evidence_finalize
  evidence_scrub_structure
  evidence_unique_gaps
);

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 8;

plan tests => $EXPECTED_TESTS;

my $base = evidence_finalize(
    {
        status        => 'pass',
        residual_gaps => ['TLS still open', 'TLS still open'],
    }
);
ok( $base->{secrets_redacted}, 'finalize marks secrets_redacted' );
is( $base->{private_beta_claimed}, 0, 'finalize refuses private-beta claim' );
is_deeply(
    $base->{residual_gaps},
    [
        'TLS still open',
        'This evidence does not claim private-beta readiness by itself.',
    ],
    'finalize dedupes gaps and adds default beta residual'
);

my $custom = evidence_finalize(
    {
        residual_gaps =>
          ['Mail harness does not claim private-beta readiness by itself.'],
    },
    extra_gaps => ['SMTP send still required'],
);
is_deeply(
    $custom->{residual_gaps},
    [
        'Mail harness does not claim private-beta readiness by itself.',
        'SMTP send still required',
    ],
    'existing private-beta residual skips default gap'
);

my $scrubbed = evidence_finalize(
    {
        status       => 'fail',
        smtp_password => 'super-secret',
        error        => 'connect failed with token mail-check-probe-token',
    },
    secrets => [ 'super-secret', 'mail-check-probe-token' ],
);
is( $scrubbed->{smtp_password}, '[redacted]', 'secret keys redacted' );
unlike(
    $scrubbed->{error},
    qr/super-secret|mail-check-probe-token/msx,
    'secret substrings scrubbed from strings'
);

is_deeply(
    evidence_unique_gaps( [ 'a', undef, 'a', q{}, 'b' ] ),
    [ 'a', 'b' ],
    'unique gaps drops empties and duplicates'
);

is_deeply(
    evidence_scrub_structure(
        { nested => { authorization => 'Bearer x', note => 'ok' } }, []
    ),
    { nested => { authorization => '[redacted]', note => 'ok' } },
    'nested credential-like keys redacted'
);

1;
