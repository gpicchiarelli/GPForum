package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use File::Temp qw(tempdir);
use JSON::MaybeXS qw(decode_json encode_json);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::Command::EvidenceValidate;
use GPForum::Service::Operations::EvidenceValidate;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 18;

plan tests => $EXPECTED_TESTS;

my $dir = tempdir( CLEANUP => 1 );

my $staging = path( $dir, 'staging.json' );
$staging->spew(
    encode_json(
        {
            check                => 'staging_host_verify',
            status               => 'pass',
            secrets_redacted     => \1,
            private_beta_claimed => 0,
            residual_gaps        => ['still open'],
        }
    )
);

my $mail = path( $dir, 'mail.json' );
$mail->spew(
    encode_json(
        {
            check                => 'mail_delivery',
            status               => 'pass',
            mode                 => 'dry_run',
            secrets_redacted     => \1,
            private_beta_claimed => 0,
            residual_gaps        => ['SMTP send still open'],
        }
    )
);

my $ok = GPForum::Service::Operations::EvidenceValidate->new->run(
    { paths => [ "$staging", "$mail" ] } );
is( $ok->{status}, 'pass', 'clean evidence validates' );
is( $ok->{check}, 'evidence_validate', 'check name set' );
is( $ok->{private_beta_claimed}, 0, 'validator refuses private-beta claim' );

my $leaky = path( $dir, 'leaky.json' );
$leaky->spew('{"check":"mail_delivery","status":"pass","smtp_password":"x"}');
my $secret = GPForum::Service::Operations::EvidenceValidate->new->run(
    { paths => ["$leaky"] } );
is( $secret->{status}, 'fail', 'secret key fails validation' );

my $claim = path( $dir, 'claim.json' );
$claim->spew(
    '{"check":"mail_delivery","status":"pass","note":"PRIVATE BETA: READY"}');
my $claimed = GPForum::Service::Operations::EvidenceValidate->new->run(
    { paths => ["$claim"] } );
is( $claimed->{status}, 'fail', 'readiness claim fails validation' );

my $old_mail = path( $dir, 'old-mail.json' );
$old_mail->spew(
    encode_json(
        { check => 'mail_delivery', status => 'pass', mode => 'dry_run' } )
);
my $warn = GPForum::Service::Operations::EvidenceValidate->new->run(
    { paths => ["$old_mail"] } );
is( $warn->{status}, 'degraded',
    'legacy mail evidence without redaction markers degrades' );

my $strict = GPForum::Service::Operations::EvidenceValidate->new->run(
    { paths => ["$old_mail"], strict => 1 } );
is( $strict->{status}, 'fail', 'strict mode fails legacy mail evidence' );

my $stress = path( $dir, 'stress.json' );
$stress->spew(
    encode_json(
        {
            mode                 => 'stress-load',
            status               => 'ok',
            secrets_redacted     => \1,
            private_beta_claimed => 0,
            residual_gaps        => ['not a beta gate'],
            plan                 => { profile => '100' },
        }
    )
);
my $stress_ok = GPForum::Service::Operations::EvidenceValidate->new->run(
    { paths => ["$stress"] } );
is( $stress_ok->{status}, 'pass', 'stress-load evidence validates' );

my $legacy_stress = path( $dir, 'legacy-stress.json' );
$legacy_stress->spew(
    encode_json(
        {
            mode          => 'stress-load',
            status        => 'ok',
            residual_gaps => ['old archive'],
            plan          => { profile => '100' },
        }
    )
);
my $legacy_warn = GPForum::Service::Operations::EvidenceValidate->new->run(
    { paths => ["$legacy_stress"] } );
is( $legacy_warn->{status}, 'degraded',
    'legacy stress without redaction markers degrades' );
my $legacy_strict = GPForum::Service::Operations::EvidenceValidate->new->run(
    { paths => ["$legacy_stress"], strict => 1 } );
is( $legacy_strict->{status}, 'fail',
    'strict mode fails legacy stress evidence' );

my $missing = GPForum::Service::Operations::EvidenceValidate->new->run(
    { paths => [] } );
is( $missing->{status}, 'fail', 'no paths fails' );

my $command = GPForum::Command::EvidenceValidate->new;
my $usage   = q{};
{
    open my $stdout, '>', \$usage or croak 'stdout';
    local *STDOUT = $stdout;
    is( $command->run('--help'), 0, 'help exits 0' );
    close $stdout or croak 'close stdout';
}
like( $usage, qr/gpforum-evidence-validate/msx, 'help names command' );
like( $usage, qr/private-beta/msx, 'help denies private-beta claim' );
like( $usage, qr/--strict/msx, 'help mentions strict mode' );

my $json = q{};
{
    open my $stdout, '>', \$json or croak 'stdout';
    local *STDOUT = $stdout;
    is( $command->run( '--json', "$staging" ), 0, 'json validate exits 0' );
    close $stdout or croak 'close stdout';
}
my $decoded = decode_json($json);
is( $decoded->{status}, 'pass', 'cli json status pass' );

my $stderr = q{};
{
    open my $err, '>', \$stderr or croak 'stderr';
    local *STDERR = $err;
    is( $command->run('--nope'), 2, 'unknown option exits usage' );
    close $err or croak 'close stderr';
}

1;
