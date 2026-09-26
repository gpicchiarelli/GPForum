# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS qw(decode_json);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::AntivirusCheck;
use GPForum::Config;
use GPForum::Service::Operations::AntivirusCheck;
use GPForum::Test::Antivirus;

our $VERSION = '0.001';

const my $EICAR_LENGTH       => 68;
const my $EXIT_USAGE         => 2;
const my $SMALL_STREAM_LIMIT => 10 * 1_024 * 1_024;

# Readiness asks whether the antivirus answers; this asks whether it scans.
my $clamd = GPForum::Config->new( antivirus => 'clamd' );

is( length GPForum::Service::Operations::AntivirusCheck->test_file,
    $EICAR_LENGTH, 'the EICAR test string is intact' );

my $working =
  _check( GPForum::Test::Antivirus->new( detects => qr/EICAR/msx ) );
my $evidence = $working->run;
is( $evidence->{status}, 'ok', 'a scanner that detects the test file is ok' );
is( $evidence->{test_file}{status}, 'infected', 'EICAR is detected' );
is( $evidence->{ordinary_file}{status},
    'clean', 'and an ordinary file passes' );
is( $working->exit_status($evidence), 0, 'exit 0' );

my $blind  = _check( GPForum::Test::Antivirus->new );
my $missed = $blind->run;
is( $missed->{status}, 'fail',
    'a scanner that answers but detects nothing fails the check' );
like( $missed->{problems}[0], qr/not [ ] detected/msx, 'saying so' );
is( $blind->exit_status($missed), 1, 'exit 1' );

my $down = _check(
    GPForum::Test::Antivirus->new(
        verdict => { status => 'error', error => 'cannot connect' }
    )
);
is( $down->run->{status}, 'fail',
    'a scanner that cannot scan fails the check' );

my $stale = _check(
    GPForum::Test::Antivirus->new(
        detects       => qr/EICAR/msx,
        health_status => 'degraded',
    )
);
is( $stale->run->{status},
    'degraded', 'a working scanner with old signatures is degraded' );

# A StreamMaxLength below the upload limit would leave large uploads
# unscanned; the check sends a file that large to find out.
my $limited = _check(
    GPForum::Test::Antivirus->new(
        detects   => qr/EICAR/msx,
        max_bytes => $SMALL_STREAM_LIMIT,
    )
)->run;
is( $limited->{status}, 'fail',
    'a clamd whose stream limit is below the upload limit fails the check' );
like( join( q{ }, @{ $limited->{problems} } ),
    qr/StreamMaxLength/msx, 'and names the setting to raise' );

# A misconfiguration is a failed check, exit 1 -- not a crash.
{
    local $ENV{GPFORUM_ANTIVIRUS} = 'bogus';
    my $check     = GPForum::Service::Operations::AntivirusCheck->new;
    my $misconfig = $check->run;
    is( $misconfig->{status}, 'fail',
        'a bad GPFORUM_ANTIVIRUS fails the check' );
    is( $check->exit_status($misconfig), 1, 'with exit 1, as documented' );
}

# From a shell without the service's environment the check would only report
# the development default; it says so rather than looking reassuring.
{
    local $ENV{GPFORUM_ENV} = undef;
    delete $ENV{GPFORUM_ENV};
    local $ENV{GPFORUM_ANTIVIRUS} = 'none';
    like(
        GPForum::Service::Operations::AntivirusCheck->new->run->{detail},
        qr/GPFORUM_ENV [ ] is [ ] not [ ] set/msx,
        'a check run outside the service environment says so'
    );
}

my $off = GPForum::Service::Operations::AntivirusCheck->new(
    config => GPForum::Config->new( antivirus => 'none' ) );
is( $off->run->{status}, 'disabled',   'scanning off is reported as disabled' );
is( $off->exit_status( $off->run ), 0, 'which is an explicit choice, exit 0' );

# The command: JSON on request, misuse exits 2.
my $command = GPForum::Command::AntivirusCheck->new( check => $working );
my $json    = _stdout( sub { return $command->run('--json') } );
is( decode_json( $json->{output} )->{status},
    'ok', 'the command reports the evidence as JSON' );
is( $json->{status}, 0, 'and exits 0 when the scanner works' );
like(
    _stdout( sub { return $command->run } )->{output},
    qr/EICAR [ ] test [ ] file: [ ] infected/msx,
    'human output by default'
);
is( _quietly( sub { return $command->run('--bogus') } ),
    $EXIT_USAGE, 'an unknown option exits 2' );

done_testing();

sub _check {
    my ($scanner) = @_;

    return GPForum::Service::Operations::AntivirusCheck->new(
        config  => $clamd,
        scanner => $scanner,
    );
}

sub _quietly {
    my ($code) = @_;

    my $ignored = q{};
    open my $quiet, '>', \$ignored or croak 'capture stderr';
    my $status;
    {
        local *STDERR = $quiet;
        $status = $code->();
    }
    close $quiet or croak 'close stderr capture';

    return $status;
}

sub _stdout {
    my ($code) = @_;

    my $output = q{};
    open my $capture, '>', \$output or croak 'capture stdout';
    my $status;
    {
        local *STDOUT = $capture;
        $status = $code->();
    }
    close $capture or croak 'close capture';

    return { output => $output, status => $status };
}

1;
