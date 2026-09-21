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

use GPForum::Command::EvidenceMeta;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 9;

plan tests => $EXPECTED_TESTS;

my $dir  = tempdir( CLEANUP => 1 );
my $path = path( $dir, 'legacy.json' );
$path->spew(
    encode_json(
        {
            check         => 'staging_host_verify',
            status        => 'pass',
            residual_gaps => ['still open'],
        }
    )
);

my $command = GPForum::Command::EvidenceMeta->new;
my $stdout  = q{};
{
    open my $out, '>', \$stdout or croak 'stdout';
    local *STDOUT = $out;
    is( $command->run("$path"), 0, 'stdout stamp exits 0' );
    close $out or croak 'close stdout';
}
my $printed = decode_json($stdout);
ok( $printed->{secrets_redacted}, 'stdout stamp marks secrets_redacted' );
is( $printed->{private_beta_claimed}, 0, 'stdout stamp refuses beta claim' );
ok( !exists decode_json( $path->slurp )->{secrets_redacted},
    'default mode leaves file unchanged' );

is( $command->run( '--write', "$path" ), 0, 'write stamp exits 0' );
my $written = decode_json( $path->slurp );
ok( $written->{secrets_redacted}, 'write stamp marks secrets_redacted' );
is( $written->{private_beta_claimed}, 0, 'write stamp refuses beta claim' );

my $usage = q{};
{
    open my $out, '>', \$usage or croak 'stdout';
    local *STDOUT = $out;
    is( $command->run('--help'), 0, 'help exits 0' );
    close $out or croak 'close stdout';
}
like( $usage, qr/gpforum-evidence-meta|private-beta/msx, 'help names command' );

1;
