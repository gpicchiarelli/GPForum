package main;

use strict;
use warnings;

use Const::Fast;
use JSON::MaybeXS qw(decode_json);
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Command::Benchmark;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 13;
const my $HTTP_OK        => 200;

plan tests => $EXPECTED_TESTS;

my $command     = GPForum::Command::Benchmark->new;
my $text_report = $command->benchmark_report(
    '--fixture', '--iterations', '2',            '--warmup',
    '1',         '--route',      '/health/live', '--route',
    '/categories',
);
my $text = $command->format_report( $text_report, 'text' );

like( $text, qr/mode=fixture/msx, 'benchmark text reports fixture mode' );
like( $text, qr/route=\/health\/live/msx,
    'benchmark text reports health route' );
like( $text, qr/route=\/categories/msx,
    'benchmark text reports categories route' );
like( $text, qr/p95_ms=/msx, 'benchmark text reports p95 latency' );
like(
    $text,
    qr/query_budget=categories:3/msx,
    'benchmark text reports query budget contract'
);
like( $text, qr/statuses=200:2/msx, 'benchmark text reports status counts' );

my $json_report = $command->benchmark_report(
    '--fixture', '--json', '--iterations', '1',
    '--warmup',  '0',      '--route',      '/search?q=welcome',
);
my $json_text = $command->format_report( $json_report, 'json' );
my $report    = decode_json($json_text);
is( $report->{mode},       'fixture', 'benchmark JSON reports fixture mode' );
is( $report->{iterations}, 1,         'benchmark JSON reports iterations' );
is( $report->{routes}[0]{route},
    '/search?q=welcome', 'benchmark JSON reports route' );
is( $report->{routes}[0]{status_codes}{$HTTP_OK},
    1, 'benchmark JSON reports status map' );
is( $report->{routes}[0]{query_budget}{max_queries},
    2, 'benchmark JSON reports query budget contract' );

throws_ok(
    sub {
        $command->run( '--iterations', '0' );
    },
    qr/Usage/msx,
    'benchmark rejects invalid iterations'
);

throws_ok(
    sub {
        $command->run( '--route', 'relative' );
    },
    qr/Usage/msx,
    'benchmark rejects relative routes'
);

1;
