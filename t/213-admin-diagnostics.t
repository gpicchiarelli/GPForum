# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Email::Sender::Transport::Failable;
use Email::Sender::Transport::Test;
use JSON::MaybeXS qw(encode_json);
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Service::Admin::Diagnostics;
use GPForum::Service::Admin::Settings;
use GPForum::Service::Identity::Mailer;
use GPForum::Test::AdminAuditLog;
use GPForum::Test::AdminWebServices;
use GPForum::Test::AllowLimiter;
use GPForum::Test::AllowPermissionGate;
use GPForum::Test::Antivirus;
use GPForum::Test::CommandIdempotency;
use GPForum::Test::DenyLimiter;
use GPForum::Test::DenyPermissionGate;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;

our $VERSION = '0.001';

const my $HTTP_OK          => 200;
const my $HTTP_FOUND       => 302;
const my $HTTP_BAD_REQUEST => 400;
const my $HTTP_FORBIDDEN   => 403;
const my $HTTP_TOO_MANY    => 429;
const my $SMTP_TIMEOUT     => 5;
const my $ADMIN            => 'admin-1';
const my $ADMIN_ADDRESS    => 'admin-1@example.test';
const my $SMTP_USER        => 'smtp-user-KNOWN';
const my $SMTP_PASSWORD    => 'smtp-password-KNOWN';
const my $VICTIM           => 'victim@example.test';

my $config = GPForum::Config->new(
    antivirus      => 'clamd',
    mail_transport => 'smtp',
    smtp_host      => 'smtp.example.test',
    smtp_password  => $SMTP_PASSWORD,
    smtp_username  => $SMTP_USER,
);

# --- The service: one message, to the actor's own address, audited. ---

my $accounts    = GPForum::Test::AdminWebServices->new;
my $transport   = Email::Sender::Transport::Test->new;
my $log         = GPForum::Test::AdminAuditLog->new;
my $diagnostics = _diagnostics( transport => $transport, log => $log );

my $sent =
  $diagnostics->send_test_mail( { actor_user_id => $ADMIN, to => $VICTIM } );
is( $sent->{outcome},           'sent', 'a test message is sent' );
is( $sent->{transport},         'smtp', 'through the configured transport' );
is( $transport->delivery_count, 1,      'once' );
my ($delivery) = $transport->deliveries;
is_deeply( $delivery->{envelope}{to},
    [$ADMIN_ADDRESS],
    q{to the administrator's own address: one in the request is ignored} );
unlike( encode_json($sent), qr/\Q$ADMIN_ADDRESS\E/msx,
    'and the result, kept as the command answer, does not copy the address' );
is(
    $delivery->{email}->get_header('Subject'),
    'GPForum test message',
    'as the console test message'
);
unlike( $delivery->{email}->get_body,
    qr{https?://}msx, 'which carries no link' );

my ($mail_audit) = @{ $log->actions('admin.mail_test_sent') };
is( $mail_audit->{actor_id},    $ADMIN, 'the send is audited with its actor' );
is( $mail_audit->{target_type}, 'user', 'naming the recipient as a user' );
is( $mail_audit->{target_id},   $ADMIN, 'who is the actor' );
is_deeply(
    $mail_audit->{metadata},
    { outcome => 'sent', transport => 'smtp', via => 'web' },
    'and its outcome'
);
unlike( encode_json($mail_audit),
    qr/\Q$ADMIN_ADDRESS\E/msx, 'without copying the address into the log' );

# A transport that refuses, quoting the credentials it was given.
my $failing = Email::Sender::Transport::Failable->new(
    transport => Email::Sender::Transport::Test->new );
$failing->fail_if(
    sub {
        return "SMTP AUTH failed for $SMTP_USER with $SMTP_PASSWORD"
          . ' at /usr/share/perl/Net/SMTP.pm line 42.';
    }
);
my $failed_log = GPForum::Test::AdminAuditLog->new;
my $failed =
  _diagnostics( transport => $failing, log => $failed_log )
  ->send_test_mail( { actor_user_id => $ADMIN } );
is( $failed->{outcome}, 'failed', 'a refused message is a failed outcome' );
like(
    $failed->{error},
    qr/SMTP [ ] AUTH [ ] failed/msx,
    q{with the transport's error}
);
unlike( $failed->{error}, qr/KNOWN/msx, 'scrubbed of the SMTP credentials' );
unlike( $failed->{error}, qr/line [ ] \d+/msx, 'and of where Perl died' );
my ($failed_audit) = @{ $failed_log->actions('admin.mail_test_sent') };
is( $failed_audit->{metadata}{outcome}, 'failed', 'a failure is audited too' );
unlike( encode_json($failed_audit), qr/KNOWN/msx, 'without the credentials' );

# Without Authen::SASL, Email::Sender confesses: its message, then a frame
# per call with that call's arguments, the recipient's address among them.
my $confessing = Email::Sender::Transport::Failable->new(
    transport => Email::Sender::Transport::Test->new );
$confessing->fail_if(
    sub {
        return
            'SMTP auth requires MIME::Base64 and Authen::SASL at'
          . " /usr/share/perl/Email/Sender/Transport/SMTP.pm line 228.\n"
          . "\tGPForum::Service::Admin::Diagnostics::_deliver(GPForum::"
          . "Service::Admin::Diagnostics=HASH(0x1), '$ADMIN_ADDRESS') called"
          . " at lib/GPForum/Service/Admin/Diagnostics.pm line 107\n";
    }
);
my $confessed_log = GPForum::Test::AdminAuditLog->new;
my $confessed =
  _diagnostics( transport => $confessing, log => $confessed_log )
  ->send_test_mail( { actor_user_id => $ADMIN } );
is(
    $confessed->{error},
    'SMTP auth requires MIME::Base64 and Authen::SASL',
    'a confessed failure keeps its message, not its stack frames'
);
unlike(
    encode_json( $confessed_log->rows ),
    qr/\Q$ADMIN_ADDRESS\E/msx,
    'whose arguments named the recipient'
);

# A server's refusal quotes the address it refused, in whatever case.
my $refusing = Email::Sender::Transport::Failable->new(
    transport => Email::Sender::Transport::Test->new );
$refusing->fail_if(
    sub {
        return "5.1.1 <\U$ADMIN_ADDRESS\E>: Recipient address rejected";
    }
);
my $refused_log = GPForum::Test::AdminAuditLog->new;
my $refused =
  _diagnostics( transport => $refusing, log => $refused_log )
  ->send_test_mail( { actor_user_id => $ADMIN } );
is(
    $refused->{error},
    '5.1.1 <[recipient]>: Recipient address rejected',
    'a refusal says why without the address'
);
unlike( encode_json( $refused_log->rows ),
    qr/\Q$ADMIN_ADDRESS\E/msxi, 'so the audit row does not hold it either' );

my $nowhere_transport = Email::Sender::Transport::Test->new;
my $nowhere_log       = GPForum::Test::AdminAuditLog->new;
my $nowhere =
  _diagnostics( transport => $nowhere_transport, log => $nowhere_log )
  ->send_test_mail( { actor_user_id => 'ghost' } );
is( $nowhere->{outcome}, 'failed',         'an account with no address fails' );
is( $nowhere_transport->delivery_count, 0, 'and sends nothing' );
is( scalar @{ $nowhere_log->actions('admin.mail_test_sent') },
    1, 'but is audited' );

# Inside a request an SMTP step may not wait Email::Sender's 120 seconds.
my $bounded = GPForum::Service::Admin::Diagnostics->new( config => $config );
is( $bounded->mailer->transport->timeout,
    $SMTP_TIMEOUT, 'the SMTP transport gives up on a stalled step in time' );

# --- The antivirus check: the shell's check, with the app's scanner. ---

my $clean_log = GPForum::Test::AdminAuditLog->new;
my $working   = _diagnostics(
    log     => $clean_log,
    scanner => GPForum::Test::Antivirus->new( detects => qr/EICAR/msx ),
)->check_antivirus( { actor_user_id => $ADMIN } );
is( $working->{status},                'ok',       'a working scanner passes' );
is( $working->{test_file}{status},     'infected', 'EICAR is detected' );
is( $working->{ordinary_file}{status}, 'clean',    'an ordinary file passes' );
my ($antivirus_audit) = @{ $clean_log->actions('admin.antivirus_checked') };
is( $antivirus_audit->{actor_id},         $ADMIN, 'the check is audited' );
is( $antivirus_audit->{metadata}{status}, 'ok',   'with its outcome' );
is( $antivirus_audit->{metadata}{test_file}{signature},
    'Eicar-Test-Signature', 'and its report' );

my $blind = _diagnostics( scanner => GPForum::Test::Antivirus->new )
  ->check_antivirus( { actor_user_id => $ADMIN } );
is( $blind->{status}, 'fail', 'a scanner that detects nothing fails' );
like( $blind->{problems}[0], qr/not [ ] detected/msx, 'saying why' );

my $command_scanner = GPForum::Test::Antivirus->new( immediate => 0 );
my $command         = _diagnostics( scanner => $command_scanner )
  ->check_antivirus( { actor_user_id => $ADMIN } );
is( $command->{status}, 'not_run',
    'a command scanner is not run inside a request' );
is( $command->{reason},      'command_scanner', 'and says so' );
is( $command_scanner->scans, 0,                 'nothing was scanned' );

my $off = GPForum::Service::Admin::Diagnostics->new(
    clock      => GPForum::Test::FixedClock->new,
    config     => GPForum::Config->new( antivirus => 'none' ),
    id_service => GPForum::Test::Id->new,
    recorder   => GPForum::Test::AdminAuditLog->new,
    settings   => GPForum::Service::Admin::Settings->new(
        config => GPForum::Config->new
    ),
)->check_antivirus( { actor_user_id => $ADMIN } );
is( $off->{status}, 'disabled', 'scanning that is off is reported as off' );
unlike( $off->{detail}, qr/shell/msx, 'in words that fit the console' );

# The settings page reads what was audited.
my $overview = $diagnostics->overview($ADMIN);
is( $overview->{mail}{recipient}, $ADMIN_ADDRESS, 'where a test would go' );
is( $overview->{mail}{latest}{result}{outcome},
    'sent', 'and how the last one went' );
is( $overview->{antivirus}{in_request}, 1, 'a clamd is checked in a request' );
is(
    _diagnostics( scanner => $command_scanner )->overview($ADMIN)
      ->{antivirus}{in_request},
    0,
    'a command scanner is not'
);

# --- The console: permission, CSRF, command id, rate limit, the page. ---

my $test     = Test::Mojo->new('GPForum');
my $web_log  = GPForum::Test::AdminAuditLog->new;
my $web_mail = Email::Sender::Transport::Test->new;
my $scanner  = GPForum::Test::Antivirus->new( detects => qr/EICAR/msx );
my $web      = _diagnostics(
    log       => $web_log,
    scanner   => $scanner,
    transport => $web_mail,
);
_install_fakes( $test, $web );

$test->post_ok('/admin/mail/test');
$test->status_is( $HTTP_FORBIDDEN, 'no session and no form token' );

$test->get_ok("/__test/session/$ADMIN")->status_is($HTTP_OK);
$test->get_ok( '/admin' => { Accept => 'application/json' } );
my $csrf_token = _json_value( $test, q{csrf_token} );

$test->get_ok('/admin/settings');
$test->status_is($HTTP_OK);
my $page = $test->tx->res->dom;
my %command_ids;
for my $action (qw(/admin/mail/test /admin/antivirus/check)) {
    my $input = $page->at(qq{form[action="$action"] input[name=command_id]});
    my $value = $input ? $input->attr('value') : q{};
    like( $value, qr/\S/msx, "$action carries a command id" );
    $command_ids{$value} = 1;
    ok( $page->at(qq{form[action="$action"] input[name=csrf_token]}),
        "$action carries the form token" );
    ok(
        $page->at(qq{form[action="$action"] button[aria-describedby]}),
        "$action explains what it does beside the button"
    );
}
is( scalar keys %command_ids, 2, 'each its own' );
like(
    $page->at('#mail-test-hint')->all_text,
    qr/\Q$ADMIN_ADDRESS\E .* smtp/msx,
    'the mail form names the address and the transport'
);

for my $action (qw(/admin/mail/test /admin/antivirus/check)) {
    $test->post_ok( $action => form => { command_id => 'no-token' } );
    $test->status_is( $HTTP_FORBIDDEN, "$action needs the form token" );
    $test->text_is( '#forum-error-heading' => 'Form expired' );

    $test->post_ok( $action => { Accept => 'application/json' } => form =>
          { csrf_token => $csrf_token } );
    $test->status_is( $HTTP_BAD_REQUEST, "$action needs a command id" );
    $test->json_has('/errors/command_id');
}
is( $web_mail->delivery_count, 0, 'none of that sent anything' );
is( $scanner->scans,           0, 'or scanned anything' );

$test->post_ok(
    '/admin/mail/test' => { Accept => 'application/json' } => form => {
        command_id => 'mail-1',
        csrf_token => $csrf_token,
        to         => $VICTIM,
    }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'           => 'mail_test_sent' );
$test->json_is( '/result/outcome'   => 'sent' );
$test->json_is( '/result/transport' => 'smtp' );
is_deeply( ( $web_mail->deliveries )[0]{envelope}{to},
    [$ADMIN_ADDRESS], 'a to= parameter changes nothing' );
is( $web_log->actions('admin.mail_test_sent')->[0]{actor_id},
    $ADMIN, 'audited as the signed-in administrator' );

$test->post_ok( '/admin/mail/test' => form =>
      { command_id => 'mail-2', csrf_token => $csrf_token } );
$test->status_is($HTTP_FOUND);
$test->header_is( Location => '/admin/settings' );
$test->get_ok('/admin/settings');
$test->text_is(
    'p.flash--success[role="status"]' => 'Test message sent to your address.' );
like(
    _section_text( $test, q{admin-mail-heading} ),
    qr/Last [ ] test [ ] message .* Sent/msx,
    'the page shows the audited outcome'
);

$web->mailer->transport($failing);
$test->post_ok( '/admin/mail/test' => form =>
      { command_id => 'mail-3', csrf_token => $csrf_token } );
$test->status_is($HTTP_FOUND);
$test->get_ok('/admin/settings');
$test->element_exists( 'p.flash--warning',
    'a failed send is not announced as a success' );
my $failed_page = $test->tx->res->body;
like(
    $failed_page,
    qr/SMTP [ ] AUTH [ ] failed/msx,
    q{the page shows the transport's error}
);
unlike( $failed_page, qr/KNOWN/msx, 'without the credentials' );
$test->post_ok(
    '/admin/mail/test' => { Accept => 'application/json' } => form => {
        command_id => 'mail-4',
        csrf_token => $csrf_token,
    }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'         => 'mail_test_failed' );
$test->json_is( '/result/outcome' => 'failed' );
unlike( $test->tx->res->body, qr/KNOWN/msx, 'nor does the JSON' );

$test->post_ok(
    '/admin/antivirus/check' => { Accept => 'application/json' } => form => {
        command_id => 'antivirus-1',
        csrf_token => $csrf_token,
    }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'                  => 'antivirus_check_passed' );
$test->json_is( '/result/test_file/status' => 'infected' );
is( $web_log->actions('admin.antivirus_checked')->[0]{actor_id},
    $ADMIN, 'the check is audited as the signed-in administrator' );

$test->post_ok( '/admin/antivirus/check' => form =>
      { command_id => 'antivirus-2', csrf_token => $csrf_token } );
$test->status_is($HTTP_FOUND);
$test->header_is( Location => '/admin/settings' );
$test->get_ok('/admin/settings');
$test->text_is(
    'p.flash--success[role="status"]' => 'Antivirus check passed.' );
my $antivirus_text = _section_text( $test, q{admin-antivirus-heading} );
like(
    $antivirus_text,
    qr/EICAR [ ] test [ ] file \s+ Detected [ ] [(]Eicar-Test-Signature[)]/msx,
    'the report says EICAR was detected'
);
like(
    $antivirus_text,
    qr/Ordinary [ ] file \s+ Passed/msx,
    'and the ordinary file passed'
);

$web->antivirus( GPForum::Test::Antivirus->new );
$test->post_ok( '/admin/antivirus/check' => form =>
      { command_id => 'antivirus-3', csrf_token => $csrf_token } );
$test->status_is($HTTP_FOUND);
$test->get_ok('/admin/settings');
$test->element_exists( 'p.flash--warning', 'a failed check is a warning' );
$test->element_exists(
    'ul[aria-labelledby="admin-antivirus-problems-heading"] li',
    'listing its problems' );
$test->content_like( qr/not [ ] detected/msx, 'in its own words' );

$web->antivirus( GPForum::Test::Antivirus->new( immediate => 0 ) );
$test->get_ok('/admin/settings');
$test->element_exists_not(
    'form[action="/admin/antivirus/check"]',
    'a command scanner offers no button'
);
$test->content_like( qr/bin\/gpforum-antivirus-check/msx,
    'and points at the shell' );
$web->antivirus($scanner);

$test->get_ok( '/admin/settings' => { 'Accept-Language' => 'it' } );
$test->text_is( '#admin-mail-heading'      => 'Posta' );
$test->text_is( '#admin-antivirus-heading' => 'Antivirus' );

# Admin writes share one rate limit.
my $delivered = $web_mail->delivery_count;
my $scanned   = $scanner->scans;
$test->app->helper(
    gp_rate_limiter => sub { return GPForum::Test::DenyLimiter->new; } );
for my $action (qw(/admin/mail/test /admin/antivirus/check)) {
    $test->post_ok( $action => { Accept => 'application/json' } => form =>
          { command_id => "limited-$action", csrf_token => $csrf_token } );
    $test->status_is( $HTTP_TOO_MANY, "$action is rate limited" );
}
is( $web_mail->delivery_count, $delivered, 'a limited send sends nothing' );
is( $scanner->scans,           $scanned,   'a limited check scans nothing' );
$test->app->helper(
    gp_rate_limiter => sub { return GPForum::Test::AllowLimiter->new; } );

# Without the console's manage permission, neither runs.
$test->app->helper(
    gp_permission_gate => sub { return GPForum::Test::DenyPermissionGate->new; }
);
for my $action (qw(/admin/mail/test /admin/antivirus/check)) {
    $test->post_ok( $action => { Accept => 'application/json' } => form =>
          { command_id => "denied-$action", csrf_token => $csrf_token } );
    $test->status_is( $HTTP_FORBIDDEN, "$action needs the manage permission" );
}
is( $web_mail->delivery_count, $delivered, 'a refused send sends nothing' );
is( $scanner->scans,           $scanned,   'a refused check scans nothing' );

done_testing();

sub _diagnostics {
    my (%input) = @_;

    my $audit = $input{log} || GPForum::Test::AdminAuditLog->new;
    return GPForum::Service::Admin::Diagnostics->new(
        accounts     => $accounts,
        antivirus    => $input{scanner},
        audit_review => $audit,
        clock        => GPForum::Test::FixedClock->new,
        config       => $config,
        id_service   => GPForum::Test::Id->new,
        mailer       => GPForum::Service::Identity::Mailer->new(
            config    => $config,
            transport => $input{transport}
              || Email::Sender::Transport::Test->new,
        ),
        recorder => $audit,
    );
}

sub _install_fakes {
    my ( $test_object, $service ) = @_;

    my $app   = $test_object->app;
    my $fakes = GPForum::Test::AdminWebServices->new;
    for my $helper (
        qw(gp_role_catalog gp_category_store gp_role_binding_store
        gp_permission_review gp_admin_audit_review gp_admin_console_reader
        gp_dead_letter_replay gp_admin_maintenance)
      )
    {
        $app->helper( $helper => sub { return $fakes; } );
    }
    $app->helper( gp_admin_diagnostics => sub { return $service; } );
    $app->helper(
        gp_command_idempotency => sub {
            return GPForum::Test::CommandIdempotency->new;
        }
    );
    $app->helper(
        gp_permission_gate => sub {
            return GPForum::Test::AllowPermissionGate->new;
        }
    );
    $app->helper(
        gp_rate_limiter => sub { return GPForum::Test::AllowLimiter->new; } );
    $app->routes->get('/__test/session/:user_id')->to(
        cb => sub {
            my ($controller) = @_;

            $controller->session( user_id => $controller->param('user_id') );
            return $controller->render( json => { ok => 1 } );
        }
    );

    return;
}

sub _json_value {
    my ( $test_object, $key ) = @_;

    my $json = $test_object->tx->res->json;

    return $json->{$key};
}

# The text of the page section a heading labels.
sub _section_text {
    my ( $test_object, $heading_id ) = @_;

    my $dom = $test_object->tx->res->dom;

    return $dom->at(qq{section[aria-labelledby="$heading_id"]})->all_text;
}

1;
