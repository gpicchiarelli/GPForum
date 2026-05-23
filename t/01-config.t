package main;

use strict;
use warnings;

use Const::Fast;
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Config;
use GPForum::Runtime;

our $VERSION = '0.001';

const my $EXPECTED_TESTS            => 16;
const my $CUSTOM_WEB_PROCESSES      => 8;
const my $CUSTOM_WORKER_PROCESSES   => 3;
const my $CUSTOM_REALTIME_PROCESSES => 2;
const my $TOO_MANY_PROCESSES        => 513;

plan tests => $EXPECTED_TESTS;

my %environment = (
    GPFORUM_ENV                => 'test',
    GPFORUM_LOG_LEVEL          => 'info',
    GPFORUM_PUBLIC_BASE_URL    => 'http://example.test',
    GPFORUM_SESSION_SECRET     => 'test-secret',
    GPFORUM_DATABASE_DSN       => 'dbi:Pg:dbname=gpforum_test',
    GPFORUM_DATABASE_USER      => 'gpforum_test',
    GPFORUM_DATABASE_PASSWORD  => 'database-secret',
    GPFORUM_WEB_PROCESSES      => $CUSTOM_WEB_PROCESSES,
    GPFORUM_WORKER_PROCESSES   => $CUSTOM_WORKER_PROCESSES,
    GPFORUM_REALTIME_PROCESSES => $CUSTOM_REALTIME_PROCESSES,
);

my $config  = GPForum::Config->from_environment( \%environment );
my $runtime = GPForum::Runtime->from_config($config);

is( $config->environment, 'test', 'environment loads from env' );
is( $config->log_level,   'info', 'log level loads from env' );
is( $config->public_base_url, 'http://example.test',
    'public base url loads from env' );
is( $config->database_dsn, 'dbi:Pg:dbname=gpforum_test',
    'database dsn loads from env' );
is( $config->database_user, 'gpforum_test', 'database user loads from env' );
is( $config->database_password,
    'database-secret', 'database password loads from env' );
is( $config->web_processes, $CUSTOM_WEB_PROCESSES,
    'web process count loads from env' );
is( $config->worker_processes, $CUSTOM_WORKER_PROCESSES,
    'worker process count loads from env' );
is( $config->realtime_processes,
    $CUSTOM_REALTIME_PROCESSES, 'realtime process count loads from env' );
is( $runtime->as_hash->{web_processes},
    $CUSTOM_WEB_PROCESSES, 'runtime mirrors web process count' );

my @connect_info = $config->database_connect_info;
is( $connect_info[0], $config->database_dsn,
    'connect info includes database dsn' );

throws_ok(
    sub {
        GPForum::Config->from_environment(
            { GPFORUM_WEB_PROCESSES => 'zero' } );
    },
    qr/\A GPFORUM_WEB_PROCESSES [ ] must [ ] be [ ] an [ ] integer/msx,
    'non-integer process count fails validation',
);

throws_ok(
    sub {
        GPForum::Config->from_environment(
            {
                GPFORUM_ENV            => 'production',
                GPFORUM_SESSION_SECRET =>
                  'gpforum-development-secret-change-me',
            },
        );
    },
    qr/\A production [ ] requires [ ] GPFORUM_SESSION_SECRET/msx,
    'production rejects default session secret',
);

throws_ok(
    sub {
        GPForum::Config->new( session_secret => q{} )->validate;
    },
    qr/\A session_secret [ ] is [ ] required/msx,
    'empty session secret fails validation',
);

throws_ok(
    sub {
        GPForum::Config->new( web_processes => 0 )->validate;
    },
    qr/\A web_processes [ ] must [ ] be [ ] >= [ ] 1/msx,
    'minimum process bound is enforced',
);

throws_ok(
    sub {
        GPForum::Config->new( worker_processes => $TOO_MANY_PROCESSES )
          ->validate;
    },
    qr/\A worker_processes [ ] must [ ] be [ ] <= [ ] 512/msx,
    'maximum process bound is enforced',
);

1;
