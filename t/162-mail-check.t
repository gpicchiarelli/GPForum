package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS qw(decode_json encode_json);
use Test::More;

use lib 'lib';
use lib 't/lib';

use Email::Sender::Transport::Test;
use GPForum::Command::MailCheck;
use GPForum::Config;
use GPForum::Service::Identity::Mailer;
use GPForum::Service::Operations::MailCheck;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 34;

plan tests => $EXPECTED_TESTS;

my $test_transport = Email::Sender::Transport::Test->new;
my $test_config    = GPForum::Config->new(
    mail_transport  => 'test',
    mail_from       => 'noreply@forum.test',
    public_base_url => 'http://forum.test',
);
my $test_mailer = GPForum::Service::Identity::Mailer->new(
    config          => $test_config,
    from_address    => 'noreply@forum.test',
    public_base_url => 'http://forum.test',
    transport       => $test_transport,
);
my $test_check = GPForum::Service::Operations::MailCheck->new(
    config => $test_config,
    mailer => $test_mailer,
);
my $test_report = $test_check->run( { mode => 'dry_run' } );
is( $test_report->{status}, 'pass', 'test transport dry-run passes' );
is( $test_report->{config}{mail_transport},
    'test', 'report includes mail_transport' );
is( $test_report->{config}{mail_from},
    'noreply@forum.test', 'report includes mail_from' );
is( $test_report->{probe}{action},
    'test_transport', 'test dry-run uses test transport probe' );
ok( $test_report->{probe}{delivery_count} >= 1,
    'test probe records a delivery' );
ok( $test_report->{secrets_redacted}, 'evidence marks secrets_redacted' );
is( $test_report->{private_beta_claimed},
    0, 'evidence refuses private-beta claim' );
ok( @{ $test_report->{residual_gaps} // [] } >= 2,
    'evidence lists residual gaps' );
unlike(
    encode_json($test_report),
    qr/smtp_password|sasl_password|mail-check-probe-token/msx,
    'JSON evidence does not leak password or probe token'
);

my $smtp_connects = 0;
my $smtp_host;
my $smtp_port;
my $smtp_check = GPForum::Service::Operations::MailCheck->new(
    config => GPForum::Config->new(
        mail_transport => 'smtp',
        mail_from      => 'noreply@forum.test',
        smtp_host      => 'smtp.example.test',
        smtp_port      => 2525,
        smtp_username  => 'relay-user',
        smtp_password  => 'super-secret-password',
        smtp_ssl       => 1,
    ),
    smtp_connector => sub {
        my ( $host, $port ) = @_;
        $smtp_connects++;
        $smtp_host = $host;
        $smtp_port = $port;
        return 1;
    },
);
my $smtp_report = $smtp_check->run( { mode => 'dry_run' } );
is( $smtp_report->{status}, 'pass', 'smtp dry-run passes on connect' );
is( $smtp_report->{probe}{action},
    'smtp_connect', 'smtp dry-run uses TCP connectivity probe' );
is( $smtp_host, 'smtp.example.test', 'smtp probe uses configured host' );
is( $smtp_port, 2525,                'smtp probe uses configured port' );
is( $smtp_report->{config}{smtp}{username_configured},
    1, 'smtp summary marks username configured' );
unlike( encode_json($smtp_report),
    qr/super-secret-password/msx, 'smtp evidence never prints the password' );
is( $smtp_connects, 1, 'smtp dry-run connects once' );

my $sendmail_check = GPForum::Service::Operations::MailCheck->new(
    config => GPForum::Config->new(
        mail_transport => 'sendmail',
        mail_from      => 'noreply@forum.test',
    ),
    sendmail_resolver => sub { return '/usr/sbin/sendmail' },
);
my $sendmail_report = $sendmail_check->run( { mode => 'dry_run' } );
is( $sendmail_report->{status}, 'pass', 'sendmail dry-run passes' );
is( $sendmail_report->{probe}{path},
    '/usr/sbin/sendmail', 'sendmail dry-run reports binary path' );

my $bad_report = GPForum::Service::Operations::MailCheck->new(
    config => GPForum::Config->new(
        mail_transport => 'pigeon',
        mail_from      => 'noreply@forum.test',
    ),
)->run( { mode => 'dry_run' } );
is( $bad_report->{status}, 'fail', 'invalid transport fails' );

my $missing_send = GPForum::Service::Operations::MailCheck->new(
    config => $test_config,
    mailer => $test_mailer,
)->run( { mode => 'send' } );
is( $missing_send->{status}, 'fail', 'send without --to fails' );

my $send_ok = GPForum::Service::Operations::MailCheck->new(
    config => $test_config,
    mailer => $test_mailer,
)->run( { mode => 'send', to => 'ops@forum.test' } );
is( $send_ok->{status}, 'pass', 'send with --to on test transport passes' );
is( $send_ok->{probe}{action}, 'send', 'send mode records send action' );
unlike(
    encode_json($send_ok),
    qr/mail-check-probe-token|super-secret-password/msx,
    'send evidence does not leak probe token'
);
ok(
    (
        grep { /lifecycle|staging [ ] SMTP/msx }
        @{ $send_ok->{residual_gaps} // [] }
    ),
    'send pass still records residual gaps'
);

my $smtp_fail_check = GPForum::Service::Operations::MailCheck->new(
    config => GPForum::Config->new(
        mail_transport => 'smtp',
        mail_from      => 'noreply@forum.test',
        public_base_url => 'http://forum.test',
        smtp_host      => 'smtp.example.test',
        smtp_port      => 2525,
        smtp_password  => 'super-secret-password',
    ),
    smtp_connector => sub {
        croak 'auth failed for password=super-secret-password';
    },
);
my $smtp_fail = $smtp_fail_check->run( { mode => 'dry_run' } );
is( $smtp_fail->{status}, 'fail', 'smtp connect failure fails probe' );
unlike(
    encode_json($smtp_fail),
    qr/super-secret-password/msx,
    'smtp failure evidence scrubs password from errors'
);

my $command = GPForum::Command::MailCheck->new( check => $test_check );
my $usage   = q{};
{
    open my $stdout, '>', \$usage or croak 'stdout';
    local *STDOUT = $stdout;
    is( $command->run('--help'), 0, 'help exits 0' );
    close $stdout or croak 'close stdout';
}
like( $usage, qr/gpforum-mail-check/msx, 'help names command' );

my $human = q{};
{
    open my $stdout, '>', \$human or croak 'stdout';
    local *STDOUT = $stdout;
    is( $command->run( '--human', '--dry-run' ), 0, 'human dry-run exits 0' );
    close $stdout or croak 'close stdout';
}
like( $human, qr/mail_transport=test/msx, 'human output includes transport' );

my $json = q{};
{
    open my $stdout, '>', \$json or croak 'stdout';
    local *STDOUT = $stdout;
    is( $command->run('--json'), 0, 'json dry-run exits 0' );
    close $stdout or croak 'close stdout';
}
my $decoded = decode_json($json);
is( $decoded->{status}, 'pass', 'json dry-run status pass' );

my $stderr = q{};
{
    open my $err, '>', \$stderr or croak 'stderr';
    local *STDERR = $err;
    is( $command->run('--nope'), 2, 'unknown option exits usage' );
    close $err or croak 'close stderr';
}
like( $stderr, qr/Unknown [ ] option/msx, 'unknown option message' );

1;
