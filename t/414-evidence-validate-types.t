# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use File::Temp    qw(tempdir);
use JSON::MaybeXS qw(encode_json);
use Mojo::File    qw(path);
use Test::More;

use lib 'lib';

use GPForum::Service::Operations::EvidenceValidate;

our $VERSION = '0.001';

# evidence-validate classifies each archived file before it applies the rules
# of its type. A check names its type; a drill names one of the three drill
# types; a staging drill is also known by its two migrate phases; stress-load
# evidence by its mode or its plan's profile. The first rule that matches, in
# that order, wins.
my $directory = tempdir( CLEANUP => 1 );
my $validator = GPForum::Service::Operations::EvidenceValidate->new;
my $counter   = 0;

my %PHASED = ( fresh_migrate => {}, upgrade_path => {} );
for my $case (
    [ { check => 'staging_host_verify' },    'staging_host_verify' ],
    [ { check => 'mail_delivery' },          'mail_delivery' ],
    [ { check => 'evidence_validate' },      'evidence_validate' ],
    [ { check => 'staging_drill' },          'staging_drill' ],
    [ { check => 'attachment_filesystem' },  'attachment_filesystem' ],
    [ { check => 'deploy_checklist' },       'deploy_checklist' ],
    [ { check => 'staging_ops_extensions' }, 'staging_ops_extensions' ],
    [ { check => 'dead_letter_check' },      'dead_letter_check' ],
    [ { check => 'mail_lifecycle_check' },   'mail_lifecycle_check' ],
    [ { drill => 'attachment_filesystem' },  'attachment_filesystem' ],
    [ { drill => 'deploy_checklist' },       'deploy_checklist' ],
    [ { drill => 'staging_ops_extensions' }, 'staging_ops_extensions' ],
    [ { drill => 'mail_delivery' },          'unknown' ],
    [ {%PHASED},                                 'staging_drill' ],
    [ { fresh_migrate => {} },                   'unknown' ],
    [ { check => 'mail_delivery', %PHASED },     'mail_delivery' ],
    [ { check => 'dead_letter_check', %PHASED }, 'staging_drill' ],
    [ { mode  => 'stress-load' },                          'stress_load' ],
    [ { plan  => { profile => 'smoke' } },                 'stress_load' ],
    [ { plan  => { profile => '1000' } },                  'stress_load' ],
    [ { plan  => { profile => '2000' } },                  'unknown' ],
    [ { check => 'mail_delivery', mode => 'stress-load' }, 'mail_delivery' ],
    [ { check => 'something_else' },                       'unknown' ],
  )
{
    my ( $content, $type ) = @{$case};
    my $file = _validated( { status => 'pass', %{$content} } );
    is( $file->{detected_type},
        $type, encode_json($content) . " is read as $type" );
}

# A type that reports its own evidence must say its status, its redaction,
# that it claims nothing, and its residual gaps; evidence-validate's own
# output only its status, and an unknown type is a warning (a failure when
# strict).
my $complete = _validated(
    {
        check                => 'mail_delivery',
        status               => 'dry-run',
        secrets_redacted     => \1,
        private_beta_claimed => 0,
        residual_gaps        => ['live SMTP unproven'],
    }
);
is_deeply( $complete->{findings}, [], 'complete evidence has no finding' );
is( $complete->{status}, 'pass', 'and passes' );

my $bare = _validated( { check => 'dead_letter_check', status => 'skipped' } );
is_deeply(
    [ map { "$_->{severity} $_->{code}" } @{ $bare->{findings} } ],
    [
        'warn missing_secrets_redacted',
        'warn bad_private_beta_claimed',
        'warn missing_residual_gaps',
    ],
    'bare evidence of a reporting type is warned about each missing field'
);
is( $bare->{status}, 'degraded', 'which degrades it' );

my $own = _validated( { check => 'evidence_validate', status => 'fail' } );
is_deeply( $own->{findings}, [],
    q{evidence-validate's own evidence needs only a status} );

my $unsupported = _validated( { check => 'mail_delivery', status => 'green' } );
is( $unsupported->{findings}[0]{code},
    'missing_status', 'a status outside the known set is refused' );
is( $unsupported->{status}, 'fail', 'and fails the file' );

my $strict = $validator->run(
    { paths => [ _write( { status => 'pass' } ) ], strict => 1 } );
is( $strict->{files}[0]{findings}[0]{severity},
    'fail', 'an unknown type fails when strict' );

my $human = $validator->format_evidence(
    $validator->run( { paths => [ _write( { status => 'pass' } ) ] } ),
    'human' );
like(
    $human,
    qr/^ [ ]{2} warn [ ] unknown_type [ ] could [ ] not [ ] classify /msx,
    'the human text lists a finding as severity, code and message'
);
like(
    $human,
    qr/^evidence-validate [ ] status=degraded $/msx,
    'under the overall status'
);

done_testing();

sub _validated ($content) {
    return $validator->run( { paths => [ _write($content) ] } )->{files}[0];
}

sub _write ($content) {
    $counter++;
    my $file = path( $directory, "evidence-$counter.json" );
    $file->spew( encode_json($content) );

    return $file->to_string;
}

1;
