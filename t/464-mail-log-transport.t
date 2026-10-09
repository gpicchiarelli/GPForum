# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use Email::Simple;
use Mojo::Log;
use Mojo::Util qw(decode);
use Test::More;

use lib 'lib';

use GPForum::Config;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Identity::LogTransport;
use GPForum::Service::Identity::Mailer;
use GPForum::Service::Operations::MailCheck;

our $VERSION = '0.001';

# The README's quick start ended at "verify your email" on any laptop without
# a mail server: the development transport, test, threw the message away and
# raw tokens are never stored (walkthrough, item 1). The log transport --
# development's default (owner decision D7) -- writes the message, link
# included, where the developer reads it; staging and production refuse it.

const my $TOKEN => 'raw-verification-token';
const my $BASE  => 'http://127.0.0.1:3000';

subtest 'development mails to the log; test and the deployed do not' => sub {
    is( GPForum::Config->from_environment( {} )->mail_transport,
        'log', 'development defaults to log' );
    is(
        GPForum::Config->from_environment( { GPFORUM_ENV => 'test' } )
          ->mail_transport,
        'test',
        'the test suite keeps the in-memory test transport'
    );
    my $refused;
    try {
        GPForum::Config->from_environment(
            {
                GPFORUM_ENV            => 'staging',
                GPFORUM_MAIL_TRANSPORT => 'log',
                GPFORUM_METRICS_TOKEN  => 'metrics-token',
                GPFORUM_SESSION_SECRET => 'staging-secret',
            }
        );
    }
    catch ($error) {
        $refused = $error;
    };
    is_deeply(
        [ map { $_->{variable} } @{ $refused ? $refused->problems : [] } ],
        ['GPFORUM_MAIL_TRANSPORT'],
        'staging refuses it, where it would print members\' tokens'
    );
    like( "$refused", qr/=log [ ] only [ ] writes [ ] mail [ ] to/msx,
        'saying why' );
    like(
        "$refused",
        qr/staging [ ] must [ ] deliver [ ] it/msx,
        'and what staging must do'
    );
};

subtest 'the message, link included, reaches the log' => sub {
    my @logged;
    my $log = Mojo::Log->new( level => 'info' );
    $log->unsubscribe('message')->on(
        message => sub ( $, $level, @lines ) {
            push @logged, [ $level, join "\n", @lines ];
        }
    );
    my $mailer = GPForum::Service::Identity::Mailer->new(
        config => GPForum::Config->from_environment( {} ),
        logger => $log,
    );
    isa_ok( $mailer->transport, 'GPForum::Service::Identity::LogTransport' );
    $mailer->send_email_verification(
        { to => 'member@example.test', token => $TOKEN } );

    my ($mail) = grep { $_->[1] =~ /^Subject:/msx } @logged;
    ok( $mail, 'the message is logged' );
    my $text = $mail ? $mail->[1] : q{};
    like(
        $text,
        qr{^ \Q$BASE\E/email/verify/\Q$TOKEN\E \n}msx,
        'with the link the member would follow'
    );
    like( $text, qr/^To: [ ] member\@example[.]test $/msx, 'its recipient' );
    like(
        $text,
        qr/^Subject: [ ] Verify [ ] your [ ] GPForum [ ] account $/msx,
        'and its subject'
    );
    like(
        $text,
        qr/\A Mail [ ] not [ ] sent [ ] [(]GPFORUM_MAIL_TRANSPORT=log[)]/msx,
        'under a line saying it was not sent'
    );
};

subtest
  'without a logger it goes to standard error, in the operator language' =>
  sub {
    my $errors = _stderr_of(
        sub {
            GPForum::Service::Identity::LogTransport->new( catalog =>
                  GPForum::Service::I18N::CliCatalog->new( language => 'it' ) )
              ->send(
                Email::Simple->create(
                    header => [ Subject => 'Reset' ],
                    body   => "$BASE/password/reset/$TOKEN",
                ),
                { to => ['member@example.test'] }
              );
        }
    );
    my $text = decode( 'UTF-8', $errors ) // q{};
    like(
        $text,
        qr/\A Posta [ ] non [ ] inviata [ ] [(]/msx,
        'an Italian operator reads it in Italian'
    );
    like(
        $text,
        qr/^To: [ ] member\@example[.]test $/msx,
        'with its recipient'
    );
    like(
        $text,
        qr{/password/reset/\Q$TOKEN\E \n \z}msx,
        'with the link, ending in a newline'
    );
  };

subtest 'mail-check knows the log transport' => sub {
    my $report;
    my $output = _stderr_of(
        sub {
            $report = GPForum::Service::Operations::MailCheck->new(
                config => GPForum::Config->from_environment( {} ) )
              ->run( { mode => 'dry_run' } );
        }
    );
    is( $report->{status},        'pass',          'a dry run passes' );
    is( $report->{probe}{action}, 'log_transport', 'naming the transport' );
    is( $output,                  q{}, 'and writes nothing to the log' );
};

done_testing();

# What a piece of code writes to standard error.
sub _stderr_of ($code) {
    my $errors = q{};
    open my $stderr, '>', \$errors or croak 'capture stderr';
    {
        local *STDERR = $stderr;
        $code->();
    }
    close $stderr or croak 'close stderr';

    return $errors;
}

1;
