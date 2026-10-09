# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp       qw(croak);
use Mojo::File qw(tempfile);
use Mojo::Log;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Service::Identity::Mailer;
use GPForum::Test::MailerLog;

our $VERSION = '0.001';

# GPFORUM_MAIL_TRANSPORT=log, development's default, writes each message --
# the verification link a developer is waiting for -- to the log, at info.
# With GPFORUM_LOG_LEVEL=warn the log kept it out of sight, and the laptop
# that had no mail server had no link either (walkthrough 1, friction 16).
# With the log set above info it now goes to standard error, which the
# terminal or the supervisor keeps.

subtest 'a log at info or below keeps the message' => sub {
    for my $level (qw(trace debug info)) {
        my ( $logged, $stderr ) = _verify($level);
        like(
            $logged,
            qr{/email/verify/TOKEN-$level}msx,
            "at $level the log has the link"
        );
        is( $stderr, q{}, 'and standard error has nothing' );
    }
};

subtest 'a log that would hide it sends it to standard error' => sub {
    for my $level (qw(warn error fatal)) {
        my ( $logged, $stderr ) = _verify($level);
        unlike( $logged, qr{/email/verify/}msx,
            "at $level the log does not have it" );
        my $subject = 'Subject: Verify your GPForum account';
        my $link    = "http://127.0.0.1:3000/email/verify/TOKEN-$level";
        like( $stderr, qr/\Q$subject\E/msx, 'standard error has the message' );
        like( $stderr, qr/\Q$link\E/msx,    'link included' );
    }
};

subtest 'a logger that cannot say its level is trusted with it' => sub {
    my $logger = GPForum::Test::MailerLog->new;
    my $stderr = _stderr_of(
        sub {
            GPForum::Service::Identity::Mailer->new(
                config => GPForum::Config->new( mail_transport => 'log' ),
                logger => $logger,
              )
              ->send_email_verification(
                { to => 'dev@example.test', token => 'TOKEN-plain' } );
        }
    );
    like(
        join( "\n", @{ $logger->lines } ),
        qr{/email/verify/TOKEN-plain}msx,
        'the logger has the link'
    );
    is( $stderr, q{}, 'and standard error nothing' );
};

done_testing();

# A verification mail through the log transport, with a Mojo::Log at the
# level given: what the log file holds and what standard error got.
sub _verify ($level) {
    my $file   = tempfile;
    my $log    = Mojo::Log->new( level => $level, path => "$file" );
    my $stderr = _stderr_of(
        sub {
            GPForum::Service::Identity::Mailer->new(
                config => GPForum::Config->new( mail_transport => 'log' ),
                logger => $log,
              )
              ->send_email_verification(
                { to => 'dev@example.test', token => "TOKEN-$level" } );
        }
    );

    return ( $file->slurp, $stderr );
}

sub _stderr_of ($code) {
    my $errors = q{};
    open my $capture, '>', \$errors or croak 'capture stderr';
    {
        local *STDERR = $capture;
        $code->();
    }
    close $capture or croak 'close stderr';

    return $errors;
}

1;
