# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';

use GPForum::Config;
use GPForum::Config::Report;

our $VERSION = '0.001';

# The walkthrough (docs/ops/evidence/2026-10-07-operator-walkthrough, section
# 4.1) started GPForum with each of these and was told nothing: prod ran with
# the development secret, a URL without a scheme went into every mail, a
# misspelt log level became a Perl warning. Each is refused now, by name.

# Everything production asks for, so a case changes only what it tests.
const my $LONG_SECRET => 's' x 32;
const my %PRODUCTION_ENV => (
    GPFORUM_ENV             => 'production',
    GPFORUM_PUBLIC_BASE_URL => 'https://forum.example.test',
    GPFORUM_MAIL_FROM       => 'forum@forum.example.test',
    GPFORUM_METRICS_TOKEN   => 'metrics-token',
    GPFORUM_SESSION_SECRET  => $LONG_SECRET,
);

subtest 'GPFORUM_ENV is one of the environments, and a typo is answered' =>
  sub {
    for my $case (
        [ prod       => 'GPFORUM_ENV=production' ],
        [ producton  => 'GPFORUM_ENV=production' ],
        [ dev        => 'GPFORUM_ENV=development' ],
        [ stagign    => 'GPFORUM_ENV=staging' ],
        [ Production => 'GPFORUM_ENV=production' ],
        [ mars       => undef ],
      )
    {
        my ( $value, $suggestion ) = @{$case};
        my ($problem) = _problems( { GPFORUM_ENV => $value } );
        is(
            GPForum::Config::Report->sentence($problem),
            'GPFORUM_ENV must be one of development, test, staging,'
              . " production, not '$value'.",
            "$value is not an environment"
        );
        is( $problem->{suggestion},
            $suggestion, 'the suggestion is ' . ( $suggestion // 'none' ) );
    }
    for my $environment (qw(development test)) {
        is(
            GPForum::Config->from_environment(
                { GPFORUM_ENV => $environment }
            )->environment,
            $environment,
            "$environment is one"
        );
    }
  };

subtest 'GPFORUM_PUBLIC_BASE_URL is a full address, https in production' =>
  sub {
    is_deeply(
        [
            map { GPForum::Config::Report->sentence($_) }
              _problems( { GPFORUM_PUBLIC_BASE_URL => 'forum.example.com' } )
        ],
        [
            'GPFORUM_PUBLIC_BASE_URL must be a full address, with http:// or'
              . q{ https:// and a host, not 'forum.example.com'.}
        ],
        'an address without a scheme is refused'
    );
    is_deeply(
        [
            map { GPForum::Config::Report->sentence($_) } _problems(
                {
                    %PRODUCTION_ENV,
                    GPFORUM_PUBLIC_BASE_URL => 'http://forum.example.com'
                }
            )
        ],
        [
                'GPFORUM_PUBLIC_BASE_URL must use https:// in production,'
              . q{ not 'http://forum.example.com'.}
        ],
        'production refuses plain http'
    );
    is_deeply(
        [
            _problems(
                {
                    %PRODUCTION_ENV,
                    GPFORUM_ENV             => 'staging',
                    GPFORUM_PUBLIC_BASE_URL =>
                      'http://staging.forum.test:8080/forum'
                }
            )
        ],
        [],
        'staging may use plain http, a port and a path'
    );
    is_deeply(
        [ _problems( { GPFORUM_PUBLIC_BASE_URL => 'http://[::1]:3000' } ) ],
        [], 'a bracketed IPv6 host is an address' );
  };

subtest 'production mail comes from the forum, not localhost' => sub {
    my ($problem) =
      _problems(
        { %PRODUCTION_ENV, GPFORUM_MAIL_FROM => 'noreply@localhost' } );
    is(
        GPForum::Config::Report->sentence($problem),
        q{GPFORUM_MAIL_FROM is 'noreply@localhost': mail servers refuse a}
          . ' sender at localhost, so production needs an address at the'
          . q{ forum's own domain.},
        'production refuses a sender at localhost'
    );
    is_deeply( [ _problems( {} ) ], [], 'development keeps noreply@localhost' );
};

subtest 'the log level, the locale and the listen address are checked' => sub {
    is_deeply(
        [
            map { GPForum::Config::Report->sentence($_) } _problems(
                {
                    GPFORUM_LOG_LEVEL      => 'verbose',
                    GPFORUM_DEFAULT_LOCALE => 'fr',
                    GPFORUM_RUNTIME_LISTEN => '8080',
                }
            )
        ],
        [
            'GPFORUM_LOG_LEVEL must be one of trace, debug, info, warn, error,'
              . q{ fatal, not 'verbose'.},
            q{GPFORUM_DEFAULT_LOCALE must be one of en, it, not 'fr'.},
            'GPFORUM_RUNTIME_LISTEN must list addresses such as'
              . q{ http://127.0.0.1:8080, not '8080'.},
        ],
        'each names its variable and what it accepts'
    );
    my ($warn) = _problems( { GPFORUM_LOG_LEVEL => 'warning' } );
    is( $warn->{suggestion}, 'GPFORUM_LOG_LEVEL=warn',
        'warning is answered with warn' );
    is_deeply(
        [
            _problems(
                {
                    GPFORUM_DEFAULT_LOCALE => 'IT',
                    GPFORUM_RUNTIME_LISTEN =>
'http://127.0.0.1:8080, http+unix://%2Frun%2Fgpforum.sock',
                }
            )
        ],
        [],
        'a shipped locale in capitals and two listen addresses are fine'
    );

    # The forum reads a region tag as its language: an environment file that
    # says it_IT started before these checks and keeps starting.
    for my $tag (qw(it_IT it-IT en_US en-gb)) {
        is_deeply( [ _problems( { GPFORUM_DEFAULT_LOCALE => $tag } ) ],
            [], "$tag is a shipped locale with its region" );
    }
    my ($posix) = _problems( { GPFORUM_DEFAULT_LOCALE => 'it_IT.UTF-8' } );
    is( $posix->{suggestion}, 'GPFORUM_DEFAULT_LOCALE=it',
        'a POSIX locale, which the forum would show in English, names the tag'
    );
};

subtest 'smtp needs its host' => sub {
    is_deeply(
        [
            map { GPForum::Config::Report->sentence($_) }
              _problems( { GPFORUM_MAIL_TRANSPORT => 'smtp' } )
        ],
        ['GPFORUM_SMTP_HOST is required when GPFORUM_MAIL_TRANSPORT is smtp.'],
        'smtp without a host is refused'
    );
    is_deeply(
        [
            _problems(
                {
                    GPFORUM_MAIL_TRANSPORT => 'smtp',
                    GPFORUM_SMTP_HOST      => 'smtp.example.test',
                }
            )
        ],
        [],
        'and accepted with one'
    );
};

subtest 'production signs sessions with a long secret' => sub {
    my $short = substr $LONG_SECRET, 1;
    my ($problem) =
      _problems( { %PRODUCTION_ENV, GPFORUM_SESSION_SECRET => $short } );
    is(
        GPForum::Config::Report->sentence($problem),
        'GPFORUM_SESSION_SECRET is 31 characters long; production needs at'
          . ' least 32.',
        'a 31-character secret is refused'
    );
    is( $problem->{generate}, 'openssl rand -hex 32',
        'saying how to make one' );
    is_deeply( [ _problems( \%PRODUCTION_ENV ) ],
        [], 'a 32-character secret is accepted' );
    is_deeply(
        [
            _problems(
                {
                    GPFORUM_ENV            => 'staging',
                    GPFORUM_METRICS_TOKEN  => 'metrics-token',
                    GPFORUM_SESSION_SECRET => 'short',
                }
            )
        ],
        [],
        'staging asks only for a secret of its own'
    );
};

subtest 'a boolean is on or off, however it is written' => sub {
    for my $word (qw(1 yes true on Yes TRUE On)) {
        is(
            GPForum::Config->from_environment( { GPFORUM_SMTP_SSL => $word } )
              ->smtp_ssl,
            1,
            "$word reads as on"
        );
    }
    for my $word (qw(0 no false off No FALSE Off)) {
        is(
            GPForum::Config->from_environment(
                { GPFORUM_RUNTIME_PROXY => $word }
            )->runtime_proxy,
            0,
            "$word reads as off"
        );
    }
    my ($problem) =
      _problems( { GPFORUM_REALTIME_LISTENER_ENABLED => 'maybe' } );
    is(
        GPForum::Config::Report->sentence($problem),
        q{GPFORUM_REALTIME_LISTENER_ENABLED must be on or off, not 'maybe'.},
        'anything else is refused, saying what it may be'
    );
    is( $problem->{example}, 'on', 'with its default as the example' );
};

done_testing();

# The problems from_environment reports for an environment; none when it is
# accepted.
sub _problems ($environment) {
    try {
        GPForum::Config->from_environment($environment);
    }
    catch ($error) {
        return @{ $error->problems };
    };

    return;
}

1;
