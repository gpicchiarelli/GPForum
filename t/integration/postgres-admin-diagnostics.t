# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Email::Sender::Transport::Failable;
use Email::Sender::Transport::Test;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::Migrate;
use GPForum::Config;
use GPForum::Service::Admin::Diagnostics;
use GPForum::Service::Admin::Workflow;
use GPForum::Service::Identity::Mailer;
use GPForum::Service::Operations::CommandIdempotency;
use GPForum::Test::Antivirus;
use GPForum::Test::FailingAuditRecorder;
use GPForum::Test::PostgresHarness;
use GPForum::Test::QuietLog;

our $VERSION = '0.001';

const my $ADMIN         => '018f1000-0000-7000-8000-00000000d1a6';
const my $GONE          => '018f1000-0000-7000-8000-00000000d1a7';
const my $ADDRESS       => 'diagnostics-admin@example.test';
const my $GONE_ADDRESS  => 'diagnostics-gone@example.test';
const my $SMTP_USER     => 'smtp-user-KNOWN';
const my $SMTP_PASSWORD => 'smtp-password-KNOWN';
const my $SLOW_SECONDS  => 2;

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all =>
      'set GPFORUM_DATABASE_DSN to run the admin diagnostics test';
}

# Quality program 6.5's two console checks against PostgreSQL: the address
# comes from the users table, each run is a command under its id and an
# audit row in the partitioned audit_log, a resubmitted form sends nothing
# more, and the settings page reads the result back from the jsonb it was
# written to.
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
GPForum::Test::PostgresHarness::quietly(
    sub { return GPForum::Command::Migrate->new->run('--apply') } );

my $schema = GPForum::Test::PostgresHarness::connect_schema();
my $dbh    = $schema->storage->dbh;
for my $user (
    [ $ADMIN, 'diag-admin', $ADDRESS ],
    [ $GONE,  'diag-gone',  $GONE_ADDRESS ]
  )
{
    $dbh->do(
        q{INSERT INTO users (id, username, display_name, email_normalized,}
          . q{ password_hash, status) VALUES (?, ?, 'Diagnostics', ?, 'x',}
          . q{ 'active')},
        undef, @{$user}
    );
}
$dbh->do( 'UPDATE users SET deleted_at = now() WHERE id = ?', undef, $GONE );

my $config = GPForum::Config->new(
    antivirus      => 'clamd',
    mail_transport => 'smtp',
    smtp_host      => 'smtp.example.test',
    smtp_password  => $SMTP_PASSWORD,
    smtp_username  => $SMTP_USER,
);
my $transport   = Email::Sender::Transport::Test->new;
my $diagnostics = _diagnostics($transport);
my $workflow    = _workflow($diagnostics);

is( $diagnostics->accounts->email_of($ADMIN),
    $ADDRESS, q{the recipient is the account's own address} );
is( $diagnostics->accounts->email_of($GONE),
    undef, 'and a deleted account has none' );

# --- The test message. ---

my $sent = $workflow->send_test_mail(
    { actor_user_id => $ADMIN, command_id => 'mail-test-1' } );
is( $sent->{status},            'ok',   'the test message command succeeds' );
is( $sent->{stored}{outcome},   'sent', 'and the message is sent' );
is( $transport->delivery_count, 1,      'once' );
is_deeply( ( $transport->deliveries )[0]{envelope}{to},
    [$ADDRESS], 'to the address in the users table' );
is_deeply(
    [
        $dbh->selectrow_array(
            q{SELECT actor_id, target_type, target_id, metadata->>'outcome',}
              . q{ metadata->>'transport', metadata->>'via' FROM audit_log}
              . q{ WHERE action = 'admin.mail_test_sent'}
        )
    ],
    [ $ADMIN, 'user', $ADMIN, 'sent', 'smtp', 'web' ],
    'audited with its actor, its outcome and the transport'
);
is(
    _count(
        q{SELECT count(*) FROM audit_log WHERE action = 'admin.mail_test_sent'}
          . q{ AND metadata::text LIKE ?},
        "%$ADDRESS%"
    ),
    0,
    'without the address in the audit row'
);
is(
    _count(
        q{SELECT count(*) FROM command_log WHERE idempotency_key = ?}
          . q{ AND command_type = 'admin.mail_test'},
        'mail-test-1'
    ),
    1,
    'the command id is recorded'
);
is(
    _count(
        q{SELECT count(*) FROM command_log WHERE payload::text LIKE ?},
        "%$ADDRESS%"
    ),
    0,
    'and its stored answer does not copy the address either'
);

my $again = $workflow->send_test_mail(
    { actor_user_id => $ADMIN, command_id => 'mail-test-1' } );
is( $again->{stored}{outcome},  'sent', 'a resubmitted form gets the answer' );
is( $transport->delivery_count, 1,      'and sends no second message' );
is(
    _count(
        q{SELECT count(*) FROM audit_log WHERE action = 'admin.mail_test_sent'}
    ),
    1,
    'nor writes a second audit row'
);

# A refused message is the outcome being tested: audited and committed, with
# the transport's error scrubbed of the credentials it quoted.
my $failing = Email::Sender::Transport::Failable->new(
    transport => Email::Sender::Transport::Test->new );
$failing->fail_if(
    sub { return "SMTP AUTH failed for $SMTP_USER with $SMTP_PASSWORD"; } );
my $refused = _workflow( _diagnostics($failing) )
  ->send_test_mail( { actor_user_id => $ADMIN, command_id => 'mail-test-2' } );
is( $refused->{status},          'ok',     'a refused message is answered' );
is( $refused->{stored}{outcome}, 'failed', 'as a failed outcome' );
my ($failed_error) =
  $dbh->selectrow_array( q{SELECT metadata->>'error' FROM audit_log}
      . q{ WHERE action = 'admin.mail_test_sent'}
      . q{ AND metadata->>'outcome' = 'failed'} );
like(
    $failed_error,
    qr/SMTP [ ] AUTH [ ] failed/msx,
    q{the audit row keeps the transport's error}
);
unlike( $failed_error, qr/KNOWN/msx, 'without the credentials' );
is(
    _count(
        q{SELECT count(*) FROM audit_log WHERE metadata::text LIKE '%KNOWN%'}),
    0,
    'no audit row holds a credential'
);

# When the audit write fails the command rolls back and its id stays free. The
# message has left by then -- mail cannot be unsent -- so a retry sends
# another, and this time it is recorded.
my $unrecorded = Email::Sender::Transport::Test->new;
my $unaudited  = _diagnostics($unrecorded);
$unaudited->recorder( GPForum::Test::FailingAuditRecorder->new );
my $lost = _workflow($unaudited)
  ->send_test_mail( { actor_user_id => $ADMIN, command_id => 'mail-test-3' } );
is( $lost->{status}, 'failed', 'a test message whose audit fails fails' );
is(
    _count(
        q{SELECT count(*) FROM command_log WHERE idempotency_key = ?},
        'mail-test-3'
    ),
    0,
    'and stores no answer for its command id'
);
my $retried = _workflow( _diagnostics($unrecorded) )
  ->send_test_mail( { actor_user_id => $ADMIN, command_id => 'mail-test-3' } );
is( $retried->{stored}{outcome}, 'sent', 'so the same id can run again' );

# The command's transaction sits idle while the SMTP server answers.
# PostgreSQL ends one idle past idle_in_transaction_session_timeout -- here a
# second, for a send that takes two -- and the audit row went with it; the
# check's transaction alone is allowed longer.
my ($idle_timeout) =
  $dbh->selectrow_array('SHOW idle_in_transaction_session_timeout');
$dbh->do(q{SET idle_in_transaction_session_timeout = '1s'});
my $slow = Email::Sender::Transport::Failable->new(
    transport => Email::Sender::Transport::Test->new );
$slow->fail_if( sub { sleep $SLOW_SECONDS; return; } );
my $patient = _workflow( _diagnostics($slow) )
  ->send_test_mail( { actor_user_id => $ADMIN, command_id => 'mail-test-4' } );
is( $patient->{status}, 'ok', 'a slow SMTP server does not fail the command' );
is( $patient->{stored}{outcome},
    'sent', 'the message it took its time over is sent' );
is(
    _count(
        q{SELECT count(*) FROM command_log WHERE idempotency_key = ?},
        'mail-test-4'
    ),
    1,
    'and recorded'
);
is( ( $dbh->selectrow_array('SHOW idle_in_transaction_session_timeout') )[0],
    '1s', 'the allowance ended with its transaction' );
$dbh->do( q{SELECT set_config('idle_in_transaction_session_timeout', ?, false)},
    undef, $idle_timeout );

# --- The antivirus check. ---

my $scanner = GPForum::Test::Antivirus->new( detects => qr/EICAR/msx );
$diagnostics->antivirus($scanner);
my $checked = $workflow->check_antivirus(
    { actor_user_id => $ADMIN, command_id => 'antivirus-1' } );
is( $checked->{status},         'ok', 'the antivirus check command succeeds' );
is( $checked->{stored}{status}, 'ok', 'and the scanner passes' );
is_deeply(
    [
        $dbh->selectrow_array(
                q{SELECT actor_id, target_type, metadata->>'status',}
              . q{ metadata->'test_file'->>'status',}
              . q{ metadata->'ordinary_file'->>'status', metadata->>'via'}
              . q{ FROM audit_log WHERE action = 'admin.antivirus_checked'}
        )
    ],
    [ $ADMIN, 'antivirus', 'ok', 'infected', 'clean', 'web' ],
    'audited with its actor and the whole report'
);
my $scans = $scanner->scans;
$workflow->check_antivirus(
    { actor_user_id => $ADMIN, command_id => 'antivirus-1' } );
is( $scanner->scans, $scans, 'a resubmitted check scans nothing' );

# --- What the settings page reads back. ---

my $overview = $diagnostics->overview($ADMIN);
is( $overview->{mail}{recipient}, $ADDRESS, 'where the next test would go' );
is( $overview->{mail}{latest}{result}{outcome},
    'sent', 'the newest test message, read from the audit log' );
is( $overview->{mail}{latest}{actor_id}, $ADMIN, 'with who sent it' );
like( $overview->{mail}{latest}{at}, qr/\A\d{4}-\d{2}-\d{2}/msx, 'and when' );
is( $overview->{antivirus}{latest}{result}{test_file}{status},
    'infected', 'and the newest check, its report decoded from jsonb' );

$schema->storage->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _diagnostics {
    my ($mail_transport) = @_;

    return GPForum::Service::Admin::Diagnostics->new(
        antivirus => GPForum::Test::Antivirus->new( detects => qr/EICAR/msx ),
        config    => $config,
        mailer    => GPForum::Service::Identity::Mailer->new(
            config    => $config,
            transport => $mail_transport,
        ),
        schema => $schema,
    );
}

sub _workflow {
    my ($service) = @_;

    return GPForum::Service::Admin::Workflow->new(
        command_idempotency =>
          GPForum::Service::Operations::CommandIdempotency->new(
            schema => $schema
          ),
        diagnostics => $service,
        logger      => GPForum::Test::QuietLog->new,
    );
}

sub _count {
    my ( $sql, @binds ) = @_;

    my ($count) = $dbh->selectrow_array( $sql, undef, @binds );

    return $count;
}

1;
