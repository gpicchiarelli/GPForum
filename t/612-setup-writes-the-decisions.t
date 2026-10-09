# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';

use GPForum::Command::Support::EnvironmentFileEdit;
use GPForum::Config;
use GPForum::Config::EnvironmentFile;

our $VERSION = '0.001';

# gpforum setup wrote the whole settings table into the environment file: 258
# lines, 10 of them set and 58 commented out (walkthrough 3, friction 10). An
# operator opening /etc/gpforum/gpforum.env met every Hypnotoad timeout before
# the address of their forum. The file holds what this installation decided
# now, each with one line saying what it is, and points to the reference
# for the rest (ADR 0125).

const my $EDIT    => 'GPForum::Command::Support::EnvironmentFileEdit';
const my $AT_MOST => 45;
const my $SECRET  => 'f' x 64;
const my $EXAMPLE => 'deploy/gpforum.env.example';
const my @DECIDED => qw(
  GPFORUM_ENV GPFORUM_PUBLIC_BASE_URL GPFORUM_SESSION_SECRET
  GPFORUM_DATABASE_DSN GPFORUM_DATABASE_USER GPFORUM_DATABASE_PASSWORD
  GPFORUM_METRICS_TOKEN GPFORUM_MAIL_TRANSPORT GPFORUM_MAIL_FROM
  GPFORUM_ANTIVIRUS
);
const my @WITH_SMTP => qw(
  GPFORUM_SMTP_HOST GPFORUM_SMTP_PORT GPFORUM_SMTP_USERNAME
  GPFORUM_SMTP_PASSWORD
);

my $file  = GPForum::Config::EnvironmentFile->render;
my @lines = split /\n/msx, $file;

subtest 'the decisions, and nothing else' => sub {
    cmp_ok( scalar @lines, '<=', $AT_MOST, "at most $AT_MOST lines" );
    is_deeply( [ $file =~ /^ (GPFORUM_\w+) = /gmsx ],
        [@DECIDED], 'the ten decisions are the lines it sets, in this order' );
    is_deeply( [ $file =~ /^ [#] (GPFORUM_\w+) = /gmsx ],
        [@WITH_SMTP], 'commented out: only what smtp would ask for' );
    like(
        $file,
        qr/^ [#] [ ] With [ ] GPFORUM_MAIL_TRANSPORT=smtp: $/msx,
        'under the condition that makes them decisions'
    );
    unlike(
        $file,
        qr/RUNTIME|REALTIME|LOG_LEVEL|Advanced/msx,
        'no tuning, no advanced block'
    );
};

subtest 'one line each, and where the rest are' => sub {
    my %summary =
      map { $_->{env} => $_->{summary} } @{ GPForum::Config->settings };
    for my $variable (@DECIDED) {
        my ($at) = grep { $lines[$_] =~ /\A \Q$variable\E = /msx } 0 .. $#lines;
        is(
            $lines[ $at - 1 ],
            "# $summary{$variable}",
            "$variable under its one-line summary"
        );
        unlike( $lines[ $at - 2 ] // q{}, qr/\A [#] /msx, 'and only one' );
    }
    like(
        $file,
        qr/\Q$EXAMPLE\E [ ] lists [ ] them [ ] all/msx,
        'the reference is named for every other setting'
    );
    like(
        $file,
        qr/gpforum [ ] doctor [ ] checks [ ] it/msx,
        'and the command that checks the file'
    );
};

subtest 'filled in as setup fills it, production accepts it' => sub {
    my @filled = split /^/msx, $file;
    for my $secret (qw(GPFORUM_SESSION_SECRET GPFORUM_METRICS_TOKEN)) {
        $EDIT->assign( \@filled, $secret, $SECRET );
    }
    $EDIT->assign( \@filled,
        GPFORUM_PUBLIC_BASE_URL => 'https://forum.gpforum.test' );
    $EDIT->assign( \@filled, GPFORUM_MAIL_FROM => 'forum@forum.gpforum.test' );
    my $config =
      GPForum::Config->from_environment( $EDIT->values_of( \@filled ) );
    is( $config->environment, 'production', 'a production configuration' );
    is(
        $config->web_processes,
        $config->automatic_web_processes,
        q{sized from the host, with nothing written for it}
    );
};

subtest 'an smtp answer lands under mail, where its line is offered' => sub {
    my @written = split /^/msx, $file;
    $EDIT->assign( \@written, GPFORUM_SMTP_HOST => 'mail.gpforum.test' );
    my $text    = join q{}, @written;
    my $offered = "#GPFORUM_SMTP_HOST=smtp.example.com\n";
    my $answer  = "GPFORUM_SMTP_HOST=mail.gpforum.test\n";
    is(
        substr(
            $text,
            index( $text, $offered ) + length $offered,
            length $answer
        ),
        $answer,
        'right after the commented-out line'
    );
    cmp_ok(
        index( $text, 'GPFORUM_SMTP_HOST=mail' ),
        '<',
        index( $text, 'GPFORUM_ANTIVIRUS=' ),
        'before the antivirus, not at the end of the file'
    );
};

subtest 'the reference still holds every setting' => sub {
    my $reference = GPForum::Config::EnvironmentFile->render_reference;
    my @current =
      map { $_->{env} } grep { !$_->{retired} } @{ GPForum::Config->settings };
    is_deeply(
        [ sort $reference =~ /^ [#]? (GPFORUM_\w+) = /gmsx ],
        [ sort @current ],
        'each current setting once'
    );
};

done_testing();

1;
