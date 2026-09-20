package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS qw(decode_json);
use Test::More;

use lib 'lib';

use GPForum::Command::StagingDrillAttachments;
use GPForum::Service::Operations::AttachmentFilesystemDrill;
use GPForum::Service::Operations::DeployChecklistDrill;

our $VERSION = '0.001';

const my $EXPECTED_TESTS    => 25;
const my $MIN_SYSTEMD_UNITS => 4;
const my $MIN_NGINX_CONFIGS => 2;

plan tests => $EXPECTED_TESTS;

_test_attachment_drill();
_test_deploy_drill();
_test_command_help();
_test_command_unknown();
_test_combined_command();

sub _test_attachment_drill {
    my $attachments =
      GPForum::Service::Operations::AttachmentFilesystemDrill->new->run( {} );
    is( $attachments->{status}, 'pass', 'attachment filesystem drill passes' );
    ok(
        $attachments->{attachments}{covered},
        'attachment drill marks covered=true'
    );
    is( $attachments->{attachments}{files},
        2, 'attachment drill restores two files' );
    is( $attachments->{attachments}{mode},
        'populated_var_attachments',
        'attachment drill uses populated var/attachments layout' );
    is( $attachments->{attachments}{workspace_layout},
        'var/attachments', 'attachment drill reports var/attachments layout' );
    ok(
        $attachments->{attachments}{wiped_before_restore},
        'attachment drill wiped source before restore'
    );

    return;
}

sub _test_deploy_drill {
    my $deploy =
      GPForum::Service::Operations::DeployChecklistDrill->new->run( {} );
    ok(
        _pass_or_degraded( $deploy->{status} ),
        'deploy checklist drill passes or degrades'
    );
    ok( @{ $deploy->{deploy_checklist}{systemd_units} } >= $MIN_SYSTEMD_UNITS,
        'deploy checklist inspects systemd units' );
    ok( @{ $deploy->{deploy_checklist}{nginx_configs} } >= $MIN_NGINX_CONFIGS,
        'deploy checklist inspects nginx configs' );
    is( $deploy->{deploy_checklist}{mode},
        'static_plus_host', 'deploy checklist mode includes host validation' );

    my $host = $deploy->{deploy_checklist}{host_validation};
    ok( $host, 'host_validation evidence present' );
    ok(
        _pass_or_skipped( $host->{systemd}{status} ),
        'systemd host check pass or skipped'
    );
    ok(
        _pass_or_skipped( $host->{nginx}{status} ),
        'nginx host check pass or skipped'
    );

    my $tools = $deploy->{deploy_checklist}{optional_tools} // {};
    if ( $tools->{nginx}{available} ) {
        is( $host->{nginx}{status},
            'pass', 'nginx -t live when nginx is on PATH' );
        is( $host->{nginx}{mode},
            'rendered_sample_nginx_t',
            'nginx host mode is rendered_sample_nginx_t' );
    }
    else {
        is( $host->{nginx}{status},
            'skipped', 'nginx host check skipped when nginx absent' );
        ok( 1, 'nginx mode not asserted when skipped' );
    }

    return;
}

sub _test_command_help {
    my $command = GPForum::Command::StagingDrillAttachments->new;
    my $usage   = q{};
    {
        open my $stdout, '>', \$usage or croak 'stdout';
        local *STDOUT = $stdout;
        is( $command->run('--help'), 0, 'help exits 0' );
        close $stdout or croak 'close stdout';
    }
    like(
        $usage,
        qr/gpforum-staging-drill-attachments/msx,
        'help names command'
    );
    like( $usage, qr/private-beta/msx,    'help denies private-beta claim' );
    like( $usage, qr/systemd-analyze/msx, 'help mentions systemd-analyze' );
    like( $usage, qr/nginx/msx,           'help mentions nginx' );

    return;
}

sub _test_command_unknown {
    my $command = GPForum::Command::StagingDrillAttachments->new;
    my $stderr  = q{};
    {
        open my $err, '>', \$stderr or croak 'stderr';
        local *STDERR = $err;
        is( $command->run('--nope'), 2, 'unknown option exits usage' );
        close $err or croak 'close stderr';
    }
    like( $stderr, qr/Unknown [ ] option/msx, 'unknown option message' );

    return;
}

sub _test_combined_command {
    my $command       = GPForum::Command::StagingDrillAttachments->new;
    my $combined_json = q{};
    {
        open my $stdout, '>', \$combined_json or croak 'stdout';
        local *STDOUT = $stdout;
        is( $command->run('--json'), 0, 'combined drill exits 0' );
        close $stdout or croak 'close stdout';
    }
    my $combined = decode_json($combined_json);
    ok(
        _pass_or_degraded( $combined->{status} ),
        'combined drill status pass or degraded'
    );
    is( $combined->{attachments_phase}{status},
        'pass', 'combined attachments phase pass' );

    return;
}

sub _pass_or_degraded {
    my ($status) = @_;

    return 1 if $status eq 'pass';
    return 1 if $status eq 'degraded';

    return 0;
}

sub _pass_or_skipped {
    my ($status) = @_;

    return 1 if $status eq 'pass';
    return 1 if $status eq 'skipped';

    return 0;
}

1;
