package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use Email::Address::XS;
use Email::Sender::Simple;
use Email::Sender::Transport::Test;
use GPForum::Config;
use GPForum::Service::Identity::Mailer;
use GPForum::Test::MailerLog;
use Test::More;

our $VERSION = '0.001';

const my $DELIVERED_MESSAGES => 3;

my $transport = Email::Sender::Transport::Test->new;
my $logger    = GPForum::Test::MailerLog->new;
my $mailer    = GPForum::Service::Identity::Mailer->new(
    from_address    => 'noreply@forum.test',
    logger          => $logger,
    public_base_url => 'http://forum.test/',
    transport       => $transport,
);

$mailer->send_password_reset(
    {
        to    => 'member@example.test',
        token => 'reset-secret-token',
    }
);
$mailer->send_email_change(
    {
        to    => 'new@example.test',
        token => 'change-secret-token',
    }
);
$mailer->send_email_verification(
    {
        to    => 'member@example.test',
        token => 'verify-secret-token',
    }
);

my @deliveries = $transport->deliveries;
is( scalar @deliveries,
    $DELIVERED_MESSAGES, 'mailer delivers each identity message' );
like(
    $deliveries[0]{email}->get_body,
    qr{http://forum[.]test/password/reset/reset-secret-token}msx,
    'password reset mail contains the reset link'
);
like(
    $deliveries[1]{email}->get_body,
    qr{http://forum[.]test/email/confirm/change-secret-token}msx,
    'email change mail contains the confirm link'
);
like(
    $deliveries[2]{email}->get_body,
    qr{http://forum[.]test/email/verify/verify-secret-token}msx,
    'verification mail contains the verify link'
);

my $log_text = join q{ }, @{ $logger->lines };
unlike( $log_text, qr/reset-secret-token/msx,
    'mailer does not log the reset token' );
unlike( $log_text, qr/change-secret-token/msx,
    'mailer does not log the email-change token' );
unlike( $log_text, qr/verify-secret-token/msx,
    'mailer does not log the verification token' );
like(
    $log_text,
    qr/identity [ ] mail [ ] delivered: [ ] password_reset/msx,
    'mailer logs password-reset delivery by kind'
);

my $from_config = GPForum::Service::Identity::Mailer->from_config(
    GPForum::Config->new( mail_transport => 'test' ) );
isa_ok(
    $from_config->transport,
    'Email::Sender::Transport::Test',
    'from_config builds the test transport'
);

ok(
    !exists $INC{'Crypt/URandom.pm'},
    'mailer tests do not load Crypt::URandom'
);

done_testing();

1;
