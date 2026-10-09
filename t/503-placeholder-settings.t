# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use English qw(-no_match_vars);
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Config;
use GPForum::Config::Report;
use GPForum::Service::I18N::CliCatalog;

our $VERSION = '0.001';

# The walkthrough of iteration 1 (docs/ops/evidence/2026-10-08-operator-
# walkthrough-1, friction 4): deploy/gpforum.env.example left as copied, its
# secrets generated, started a production forum whose every mail linked to
# https://forum.example.com, from forum@forum.example.com. And
# GPFORUM_MAIL_TRANSPORT=test, which sends nothing, was taken in production
# (friction 16). Both now stop the start, each naming its variable.

const my %DEPLOYED => (
    GPFORUM_SESSION_SECRET  => 'a' x 64,
    GPFORUM_METRICS_TOKEN   => 'b' x 32,
    GPFORUM_PUBLIC_BASE_URL => 'https://forum.gpforum.test',
    GPFORUM_MAIL_FROM       => 'forum@forum.gpforum.test',
);

const my @EXAMPLE_ADDRESSES => (
    'https://forum.example.com', 'https://example.com/forum',
    'https://forum.example.net', 'https://forum.EXAMPLE.org:8443',
    'https://forum.example',     'https://forum.invalid',
    'https://forum.example.com.',
);
const my @EXAMPLE_SENDERS => qw(
  forum@forum.example.com noreply@example.org
  forum@example.net forum@forum.example forum@forum.invalid
);

subtest 'staging and production refuse the example addresses' => sub {
    for my $environment (qw(staging production)) {
        for my $address (@EXAMPLE_ADDRESSES) {
            is_deeply(
                [
                    _keys(
                        GPFORUM_ENV             => $environment,
                        GPFORUM_PUBLIC_BASE_URL => $address
                    )
                ],
                [ [ GPFORUM_PUBLIC_BASE_URL => 'config.placeholder_url' ] ],
                "$environment refuses $address"
            );
        }
        for my $sender (@EXAMPLE_SENDERS) {
            is_deeply(
                [
                    _keys(
                        GPFORUM_ENV       => $environment,
                        GPFORUM_MAIL_FROM => $sender
                    )
                ],
                [ [ GPFORUM_MAIL_FROM => 'config.placeholder_mail_from' ] ],
                "$environment refuses $sender"
            );
        }
    }
};

subtest 'a real name that only looks like one is taken' => sub {
    for my $address (
        qw(https://myexample.com https://example.com.au https://examples.org
        https://forum.example.com.gpforum.test)
      )
    {
        is_deeply(
            [
                _keys(
                    GPFORUM_ENV             => 'production',
                    GPFORUM_PUBLIC_BASE_URL => $address
                )
            ],
            [],
            "$address is not an example"
        );
    }
    is_deeply(
        [
            _keys(
                GPFORUM_ENV       => 'production',
                GPFORUM_MAIL_FROM => 'forum@forum.example.com.gpforum.test'
            )
        ],
        [],
        'nor a sender at one'
    );
};

subtest 'development keeps them: a laptop sends no real mail' => sub {
    is_deeply(
        [
            _keys(
                GPFORUM_ENV             => 'development',
                GPFORUM_PUBLIC_BASE_URL => 'https://forum.example.com',
                GPFORUM_MAIL_FROM       => 'forum@forum.example.com'
            )
        ],
        [],
        'development takes the template addresses'
    );
};

subtest 'the sentence says what the address is and offers no example' => sub {
    my $problems = _problems(
        GPFORUM_ENV             => 'production',
        GPFORUM_PUBLIC_BASE_URL => 'https://forum.example.com',
        GPFORUM_MAIL_FROM       => 'forum@forum.example.com',
    );
    is( scalar @{$problems}, 2, 'both placeholders, in one report' );
    is( $problems->[0]{example},
        undef,
        q{no "Example:" line: the template's example is the one refused} );

    my %english = _sentences( $problems, 'en' );
    is(
        $english{GPFORUM_PUBLIC_BASE_URL},
        q{GPFORUM_PUBLIC_BASE_URL is 'https://forum.example.com', an example}
          . ' address that leads nowhere; production needs the one members'
          . ' reach this forum at.',
        'the address, in English'
    );
    is(
        $english{GPFORUM_MAIL_FROM},
        q{GPFORUM_MAIL_FROM is 'forum@forum.example.com', an example address}
          . ' mail servers will not deliver from; production needs one at the'
          . q{ forum's own domain.},
        'the sender, in English'
    );
    unlike(
        GPForum::Service::I18N::CliCatalog->new( language => 'en' )
          ->config_report($problems),
        qr/Example:/msx,
        'with no example under either'
    );

    my %italian = _sentences( $problems, 'it' );
    is(
        $italian{GPFORUM_PUBLIC_BASE_URL},
        q{GPFORUM_PUBLIC_BASE_URL vale 'https://forum.example.com', un}
          . q{ indirizzo d'esempio che non porta da nessuna parte; in}
          . ' production serve quello a cui i membri raggiungono questo forum.',
        'the address, in Italian'
    );
    is(
        $italian{GPFORUM_MAIL_FROM},
        q{GPFORUM_MAIL_FROM vale 'forum@forum.example.com', un indirizzo}
          . q{ d'esempio da cui i server di posta non consegnano; in}
          . ' production ne serve uno del dominio del forum.',
        'the sender, in Italian'
    );
};

subtest 'production refuses the test transport it is told to use' => sub {
    is_deeply(
        [
            _keys(
                GPFORUM_ENV            => 'production',
                GPFORUM_MAIL_TRANSPORT => 'test'
            )
        ],
        [ [ GPFORUM_MAIL_TRANSPORT => 'config.test_transport' ] ],
        'GPFORUM_MAIL_TRANSPORT=test stops production'
    );
    my ($problem) = @{
        _problems(
            GPFORUM_ENV            => 'production',
            GPFORUM_MAIL_TRANSPORT => 'test'
        )
    };
    is(
        { _sentences( [$problem], 'en' ) }->{GPFORUM_MAIL_TRANSPORT},
        'GPFORUM_MAIL_TRANSPORT=test keeps mail in memory and sends none;'
          . ' production must deliver it, with sendmail or smtp.',
        'in English'
    );
    is(
        { _sentences( [$problem], 'it' ) }->{GPFORUM_MAIL_TRANSPORT},
        'GPFORUM_MAIL_TRANSPORT=test tiene la posta in memoria e non ne invia;'
          . ' in production va consegnata, con sendmail o smtp.',
        'in Italian'
    );
    is( $problem->{example}, 'sendmail', 'offering the one it should be' );

    is_deeply(
        [
            _keys(
                GPFORUM_ENV            => 'staging',
                GPFORUM_MAIL_TRANSPORT => 'test'
            )
        ],
        [],
        'staging may still keep its mail in memory'
    );
    is(
        GPForum::Config->from_environment(
            { %DEPLOYED, GPFORUM_ENV => 'production' }
        )->mail_transport,
        'sendmail',
        'production left alone sends with sendmail'
    );
    lives_ok {
        GPForum::Config->new(
            environment     => 'production',
            session_secret  => $DEPLOYED{GPFORUM_SESSION_SECRET},
            metrics_token   => $DEPLOYED{GPFORUM_METRICS_TOKEN},
            mail_from       => $DEPLOYED{GPFORUM_MAIL_FROM},
            public_base_url => $DEPLOYED{GPFORUM_PUBLIC_BASE_URL},
        )->validate;
    }
    'a configuration the test suite builds keeps test, its plain default';
};

done_testing();

sub _problems (%environment) {
    my $problems = [];
    eval {
        GPForum::Config->from_environment( { %DEPLOYED, %environment } );
        1;
    } or $problems = $EVAL_ERROR->problems;

    return $problems;
}

# Each problem's sentence, by its variable, in the language given.
sub _sentences ( $problems, $language ) {
    my $translator =
      GPForum::Service::I18N::CliCatalog->new( language => $language )
      ->translator;

    return map {
        $_->{variable} => GPForum::Config::Report->sentence( $_, $translator )
    } @{$problems};
}

sub _keys (%environment) {
    return map { [ $_->{variable}, $_->{key} ] } @{ _problems(%environment) };
}

1;
