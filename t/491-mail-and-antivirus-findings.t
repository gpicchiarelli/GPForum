# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';

use GPForum::Config;
use GPForum::OS;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::AntivirusCheck;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::MailCheck;

our $VERSION = '0.001';

# The walkthrough found mail-check passing a sendmail binary on a host whose
# mail server relays nowhere, and antivirus-check saying one connect error
# eight times without a fix. What they say now: what a dry run proved and
# what it did not, and a clamd that does not answer once, with what to do.

const my $SENDMAIL => '/usr/sbin/sendmail';
const my $FROM     => 'forum@forum.example.org';

subtest 'a dry run says what it proved, and how to prove the rest' => sub {
    my $development = _mail( 'development', 'linux' );
    my $found       = $development->findings( _sendmail_evidence() );
    is( $found->status, 'ok', 'a sendmail program found is not a failure' );
    is_deeply(
        [ split /\n/msx, $found->human_text ],
        [
            "\N{CHECK MARK} mail: from $FROM through sendmail at $SENDMAIL",
            '    That shows a program is there, not that mail leaves this'
              . ' host.',
            '    To prove delivery, send one to yourself: gpforum mail-check'
              . ' --send --to ADDRESS --human',
            q{},
            'Nothing to fix.',
        ],
        'but it says a program is not a delivery, and how to send one'
    );

    _says(
        _mail( 'production', 'linux' )
          ->findings( _sendmail_evidence() )
          ->human_text,
        [
            'port 25 is often blocked', 'SPF',
            'PTR record',               'GPFORUM_MAIL_TRANSPORT=smtp'
        ],
        'deployed, it adds what a VPS needs to deliver at all'
    );

    my $smtp = $development->findings(
        {
            status => 'pass',
            config => { mail_transport => 'smtp', mail_from => $FROM },
            probe  => {
                status => 'pass',
                action => 'smtp_connect',
                host   => 'smtp.example.net',
                port   => 587,
            },
        }
    )->human_text;
    like(
        $smtp,
        qr/through [ ] smtp[.]example[.]net:587, [ ] which [ ] answers$/msx,
        'an SMTP port that answers is said as that'
    );
    like(
        $smtp,
        qr/not [ ] that [ ] the [ ] server [ ] takes/msx,
        'and not as a server that takes the message'
    );

    like(
        $development->findings(
            {
                status => 'pass',
                config => { mail_transport => 'log' },
                probe  => { status => 'pass', action => 'log_transport' },
            }
        )->human_text,
        qr/written [ ] to [ ] the [ ] log, [ ] not [ ] sent/msx,
        'the log transport is said to send nothing'
    );
};

subtest 'what it could not prove comes with the fix' => sub {
    my $missing = _mail( 'production', 'linux' )->findings(
        {
            status => 'fail',
            config => { mail_transport => 'sendmail' },
            error  => 'sendmail binary not found on PATH or common locations',
            probe  => { status => 'fail', action => 'sendmail_path' },
        }
    );
    is( $missing->exit_status, 1, 'no sendmail is a failure' );
    is_deeply(
        [ grep { /\A \s/msx } split /\n/msx, $missing->human_text ],
        [
            '    Fix: install a mail server, such as postfix',
            '         or send through a provider: GPFORUM_MAIL_TRANSPORT=smtp'
              . ' and GPFORUM_SMTP_HOST in /etc/gpforum/gpforum.env',
        ],
        'naming a mail server, or the settings and the file for a relay'
    );

    my $refused = _mail( 'development', 'linux' )->findings(
        {
            status => 'fail',
            config => { mail_transport => 'smtp' },
            error  => 'SMTP TCP connect failed to smtp.example.net:25',
            probe  => {
                status => 'fail',
                action => 'smtp_connect',
                host   => 'smtp.example.net',
                port   => 25,
            },
        }
    )->human_text;
    like(
        $refused,
        qr/smtp[.]example[.]net:25 [ ] does [ ] not [ ] answer/msx,
        'a server that does not answer is named'
    );
    like(
        $refused,
        qr/GPFORUM_SMTP_HOST [ ] and [ ] GPFORUM_SMTP_PORT [ ] in [ ] your/msx,
        'with the settings to check, in the shell during development'
    );

    like(
        _mail( 'development', 'linux' )->findings(
            {
                status => 'fail',
                config => { mail_transport => 'smtp' },
                probe  => { status         => 'fail', action => 'send' },
            }
        )->human_text,
        qr/--send [ ] needs [ ] an [ ] address .* --send [ ] --to/msx,
        '--send without --to says to add one'
    );
};

subtest 'a clamd that does not answer is said once, with what to do' => sub {
    my $socket   = tempdir( CLEANUP => 1 ) . '/clamd.ctl';
    my $check    = _antivirus( 'production', 'linux', $socket );
    my $evidence = $check->run;
    is( $evidence->{status}, 'fail', 'a clamd that is not there fails' );

    my $text = $check->findings($evidence)->human_text;
    my @said = $text =~ /\Q$socket\E/gmsx;
    is( scalar @said, 1, 'and its socket is named once, not eight times' );
    is_deeply(
        [ split /\n/msx, $text ],
        [
            "\N{BALLOT X} antivirus: clamd does not answer at $socket",
            '    Detail: No such file or directory',
            '    Fix: sudo apt install clamav-daemon clamav-freshclam',
            '         or, if it is installed, start it: sudo systemctl enable'
              . q{ --now clamav-daemon (clamd waits for freshclam's first}
              . ' download)',
'         or set GPFORUM_ANTIVIRUS=none in /etc/gpforum/gpforum.env,'
              . ' and uploads are checked for format only',
            q{},
            '1 thing to fix.',
        ],
        'with the packages, the service and the setting, on Debian'
    );

    my $mac = _antivirus( 'development', 'darwin', $socket );
    _says(
        $mac->findings( $mac->run )->human_text,
        [
            "Fix: brew install clamav\n",
            'start it: brew services start clamav '
        ],
        'and with Homebrew, without sudo, on macOS'
    );
};

subtest 'scanning off, working, and with old signatures' => sub {
    my $off = { status => 'disabled', engine => 'none' };
    is( _antivirus( 'development', 'linux' )->findings($off)->status,
        'ok', 'off is the development default' );
    my $deployed = _antivirus( 'production', 'linux' )->findings($off);
    is( $deployed->status, 'degraded', 'and a warning once deployed' );
    like(
        $deployed->human_text,
        qr/then [ ] set [ ] GPFORUM_ANTIVIRUS=clamd [ ] in [ ] /msx,
        'saying to install clamd and name it'
    );

    my $engine = 'ClamAV 1.4.2/27434';
    like(
        _antivirus( 'production', 'linux' )->findings(
            {
                status => 'ok',
                engine => 'clamd',
                health => { status => 'ok', engine => $engine },
            }
        )->human_text,
        qr/^\N{CHECK MARK} [ ] antivirus: [ ] \Q$engine\E [ ] finds/msx,
        'a working engine is named'
    );
    like(
        _antivirus( 'production', 'linux' )->findings(
            {
                status => 'degraded',
                engine => 'clamd',
                health => {
                    status => 'degraded',
                    engine => $engine,
                    error  => 'signatures older than three days; is freshclam'
                      . ' running?',
                },
            }
        )->human_text,
        qr/update [ ] the [ ] signatures: [ ] sudo [ ] systemctl [ ]/msx,
        'and old signatures come with the command that starts freshclam'
    );
};

subtest 'in Italian' => sub {
    my $check = _mail( 'development', 'linux', 'it' );
    _says(
        $check->findings( _sendmail_evidence() )->human_text,
        [ "posta: da $FROM tramite sendmail", 'Per provare la consegna' ],
        'mail-check speaks the operator language'
    );
};

done_testing();

# Each fragment is in the text.
sub _says ( $text, $fragments, $label ) {
    is_deeply( [ grep { index( $text, $_ ) < 0 } @{$fragments} ], [], $label );

    return;
}

sub _host ( $environment, $os, $language = 'en' ) {
    return GPForum::Service::Operations::Host->new(
        catalog =>
          GPForum::Service::I18N::CliCatalog->new( language => $language ),
        environment => $environment,
        os          => GPForum::OS->from_name($os),
    );
}

sub _mail ( $environment, $os, $language = 'en' ) {
    return GPForum::Service::Operations::MailCheck->new(
        host => _host( $environment, $os, $language ) );
}

sub _antivirus ( $environment, $os, $socket = undef ) {
    return GPForum::Service::Operations::AntivirusCheck->new(
        host   => _host( $environment, $os ),
        config => GPForum::Config->new(
            antivirus                 => 'clamd',
            antivirus_socket          => $socket,
            antivirus_timeout_seconds => 1,
        ),
    );
}

sub _sendmail_evidence {
    return {
        status => 'pass',
        config => { mail_transport => 'sendmail', mail_from => $FROM },
        probe  => {
            status => 'pass',
            action => 'sendmail_path',
            path   => $SENDMAIL,
        },
    };
}

1;
