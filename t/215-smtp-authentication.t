# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use English qw(-no_match_vars);
use IO::Socket::INET;
use MIME::Base64 qw(decode_base64);
use Test::More;

use lib 'lib';

use GPForum::Config;
use GPForum::Service::Identity::Mailer;

our $VERSION = '0.001';

const my $USER     => 'forum-mailer';
const my $PASSWORD => 'relay-secret';

# What the relay answers to each command; anything else gets 250.
my %ANSWER = (
    AUTH => \&_auth,
    DATA => \&_data,
    EHLO => sub { _say( $_[0], '250-relay.test', '250 AUTH PLAIN' ); return; },
    QUIT => sub { _say( $_[0], '221 bye' ); return 'quit'; },
    RCPT => \&_rcpt,
);

# An SMTP relay that asks for a login: what most hosted relays are. Net::SMTP
# answers AUTH only through Authen::SASL, which it loads at run time and
# which nothing declared, so every installation with GPFORUM_SMTP_USERNAME
# failed at the first message -- sign-up confirmations and password resets
# included. This relay accepts AUTH PLAIN and records what it was told.
my $server = IO::Socket::INET->new(
    Listen    => 1,
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Proto     => 'tcp',
    ReuseAddr => 1,
) or BAIL_OUT("cannot listen: $OS_ERROR");
pipe my $reader, my $writer or BAIL_OUT("cannot pipe: $OS_ERROR");

my $pid = fork;
if ( !defined $pid ) {
    BAIL_OUT("cannot fork: $OS_ERROR");
}
if ( !$pid ) {
    close $reader or exit 1;
    _relay( $server, $writer );
    exit 0;
}
close $writer or BAIL_OUT("cannot close: $OS_ERROR");

my $mailer = GPForum::Service::Identity::Mailer->new(
    config => GPForum::Config->new(
        mail_transport => 'smtp',
        smtp_host      => '127.0.0.1',
        smtp_password  => $PASSWORD,
        smtp_port      => $server->sockport,
        smtp_username  => $USER,
    ),
    smtp_timeout => 5,
);
my $sent =
  eval { $mailer->send_test_message( { to => 'admin@example.test' } ) };
my $error = $EVAL_ERROR;
waitpid $pid, 0;
my %relay;
while ( my $line = <$reader> ) {
    chomp $line;
    my ( $key, $value ) = split /=/msx, $line, 2;
    $relay{$key} = $value;
}

ok( $sent && !$error, 'a relay that asks for a login gets one' )
  or diag( $error || explain($sent) );
is( $relay{auth}, "$USER:$PASSWORD",    'with the configured credentials' );
is( $relay{rcpt}, 'admin@example.test', 'and the message is delivered' );

done_testing();

sub _relay {
    my ( $listener, $report ) = @_;

    my $client = $listener->accept or return;
    _say( $client, '220 relay.test ESMTP' );
    while ( my $line = <$client> ) {
        $line =~ s/\r?\n\z//msx;
        my ($verb) = $line =~ /\A (\w+)/msx;
        my $answer = $ANSWER{ uc( $verb // q{} ) }
          // sub { _say( $_[0], '250 OK' ); return; };
        last if ( $answer->( $client, $line, $report ) // q{} ) eq 'quit';
    }
    close $client or return;

    return;
}

sub _say {
    my ( $client, @lines ) = @_;

    for my $line (@lines) {
        print {$client} "$line\r\n" or return;
    }

    return;
}

sub _auth {
    my ( $client, $line, $report ) = @_;

    my ($payload) = $line =~ /\A AUTH [ ] PLAIN [ ]? (\S*)/imsx;
    if ( !length( $payload // q{} ) ) {
        _say( $client, '334 ' );
        $payload = <$client> // q{};
        $payload =~ s/\r?\n\z//msx;
    }
    my ( undef, $user, $password ) = split /\0/msx, decode_base64($payload);
    print {$report} "auth=$user:$password\n" or return;
    _say( $client, '235 2.7.0 Authentication successful' );

    return;
}

sub _rcpt {
    my ( $client, $line, $report ) = @_;

    my ($recipient) = $line =~ /<([^>]+)>/msx;
    print {$report} "rcpt=$recipient\n" or return;
    _say( $client, '250 OK' );

    return;
}

sub _data {
    my ($client) = @_;

    _say( $client, '354 go ahead' );
    while ( my $body = <$client> ) {
        last if $body =~ /\A [.] \r?\n \z/msx;
    }
    _say( $client, '250 queued' );

    return;
}

1;
