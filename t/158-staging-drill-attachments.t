package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS qw(decode_json);
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Command::StagingDrillAttachments;
use GPForum::Service::Operations::AttachmentFilesystemDrill;
use GPForum::Service::Operations::DeployChecklistDrill;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 14;

plan tests => $EXPECTED_TESTS;

my $attachments =
  GPForum::Service::Operations::AttachmentFilesystemDrill->new->run( {} );
is( $attachments->{status}, 'pass', 'attachment filesystem drill passes' );
ok( $attachments->{attachments}{covered},
    'attachment drill marks covered=true' );
is( $attachments->{attachments}{files}, 2, 'attachment drill restores two files' );

my $deploy =
  GPForum::Service::Operations::DeployChecklistDrill->new->run( {} );
is( $deploy->{status}, 'pass', 'deploy checklist drill passes' );
ok( @{ $deploy->{deploy_checklist}{systemd_units} } >= 4,
    'deploy checklist inspects systemd units' );
ok( @{ $deploy->{deploy_checklist}{nginx_configs} } >= 2,
    'deploy checklist inspects nginx configs' );

my $command = GPForum::Command::StagingDrillAttachments->new;
my $usage   = q{};
{
    open my $stdout, '>', \$usage or croak 'stdout';
    local *STDOUT = $stdout;
    is( $command->run('--help'), 0, 'help exits 0' );
    close $stdout or croak 'close stdout';
}
like( $usage, qr/gpforum-staging-drill-attachments/msx, 'help names command' );
like( $usage, qr/private-beta/msx, 'help denies private-beta claim' );

my $stderr = q{};
{
    open my $err, '>', \$stderr or croak 'stderr';
    local *STDERR = $err;
    is( $command->run('--nope'), 2, 'unknown option exits usage' );
    close $err or croak 'close stderr';
}
like( $stderr, qr/Unknown [ ] option/msx, 'unknown option message' );

my $combined_json = q{};
{
    open my $stdout, '>', \$combined_json or croak 'stdout';
    local *STDOUT = $stdout;
    is( $command->run('--json'), 0, 'combined drill exits 0' );
    close $stdout or croak 'close stdout';
}
my $combined = decode_json($combined_json);
is( $combined->{status}, 'pass', 'combined drill status pass' );
is( $combined->{attachments_phase}{status},
    'pass', 'combined attachments phase pass' );

1;
