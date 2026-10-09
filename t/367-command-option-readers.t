# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use IPC::Open3 qw(open3);
use Symbol     qw(gensym);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::Benchmark;
use GPForum::Command::HypnotoadBenchmark;
use GPForum::Command::HypnotoadScaling;
use GPForum::Command::PerformanceSeed;
use GPForum::Command::QueryPlanEvidence;
use GPForum::Command::Usage;
use GPForum::X::Usage;

our $VERSION = '0.001';

# The option readers the benchmark commands share in Command::Usage, where
# each of five commands kept its own copy of the loop and the number checks:
# what a shape accepts, what a table sets, and that anything else is misuse
# carrying the command's own usage text.

const my $USAGE             => 'Usage: test [--n N]';
const my $EXIT_USAGE        => 2;
const my $EXIT_STATUS_SHIFT => 8;
const my $MEDIUM_USERS      => 25;
const my $SMALL_THREADS     => 12;
const my @WORKER_SET        => ( 2, 4 );

const my %SHAPE_CASES => (
    positive_integer => {
        accepted => [qw(1 9 10 123456)],
        refused  => [ qw(0 01 -1 1.5 x), q{}, ' 1', "1\n" ],
    },
    non_negative_integer => {
        accepted => [qw(0 7 007 42)],
        refused  => [ qw(-1 1.5 x), q{}, '1 ' ],
    },
    non_negative_number => {
        accepted => [qw(0 1 .5 0.25 12.75)],
        refused  => [ qw(1. -1 x 1e3), q{.}, q{} ],
    },
);

_test_shapes();
_test_choice_and_value();
_test_parse_options();
_test_command_tables();
_test_outbox_benchmark_script();

done_testing();

sub _test_shapes {
    for my $shape ( sort keys %SHAPE_CASES ) {
        for my $value ( @{ $SHAPE_CASES{$shape}{accepted} } ) {
            is(
                GPForum::Command::Usage->option_number(
                    $value, $shape, $USAGE
                ),
                0 + $value,
                "$shape accepts '$value' as a number"
            );
        }
        for my $value ( @{ $SHAPE_CASES{$shape}{refused} }, undef ) {
            my $shown = $value // 'nothing';
            _misuse_ok(
                sub {
                    GPForum::Command::Usage->option_number( $value, $shape,
                        $USAGE );
                },
                "$shape refuses '$shown'"
            );
        }
    }

    return;
}

sub _test_choice_and_value {
    is( GPForum::Command::Usage->option_choice( 'b', [qw(a b)], $USAGE ),
        'b', 'a listed choice is returned' );
    _misuse_ok(
        sub { GPForum::Command::Usage->option_choice( 'c', [qw(a b)], $USAGE ) }
        ,
        'an unlisted choice is misuse'
    );
    _misuse_ok(
        sub {
            GPForum::Command::Usage->option_choice( undef, [qw(a b)], $USAGE );
        },
        'a missing choice is misuse'
    );
    is( GPForum::Command::Usage->option_value( '/x', qr{\A /}msx, $USAGE ),
        '/x', 'a value matching its pattern is returned' );
    _misuse_ok(
        sub {
            GPForum::Command::Usage->option_value( 'x', qr{\A /}msx, $USAGE );
        },
        'a value missing its pattern is misuse'
    );

    return;
}

sub _test_parse_options {
    my %table = (
        usage    => $USAGE,
        switches => { '--both' => { a => 1, b => 2 }, '--off' => { a => 0 } },
        numbers  => { '--n'    => [ n => 'positive_integer' ] },
        values   => {
            '--name' => sub ( $options, $value ) {
                push @{ $options->{names} }, $value;
            },
        },
    );
    my $defaults = sub { return { a => 9, b => 9, n => 1, names => [] }; };

    is_deeply(
        GPForum::Command::Usage->parse_options(
            [qw(--both --off --n 12 --name x --name y)], $defaults->(),
            \%table
        ),
        { a => 0, b => 2, n => 12, names => [qw(x y)] },
        'switches set their keys in order, numbers and values take what follows'
    );
    is_deeply(
        GPForum::Command::Usage->parse_options( [], $defaults->(), \%table ),
        $defaults->(), 'no arguments leave the defaults' );

    my @arguments = qw(--n 3);
    GPForum::Command::Usage->parse_options( \@arguments, $defaults->(),
        \%table );
    is_deeply( \@arguments, [qw(--n 3)],
        'the caller\'s argument list is left as it was' );

    for my $misuse ( [qw(--bogus)], [qw(--n)], [qw(--n 0)], [qw(--n 3 x)] ) {
        _misuse_ok(
            sub {
                GPForum::Command::Usage->parse_options( $misuse,
                    $defaults->(), \%table );
            },
            "'@{$misuse}' is misuse"
        );
    }

    return;
}

# What the converted commands read from a command line, beyond what t/366
# already pins: the order rule of performance-seed's numbers and --profile,
# and the profiles each command accepts.
sub _test_command_tables {
    is_deeply(
        [ GPForum::Command::PerformanceSeed->profiles ],
        [qw(small medium hot-thread)],
        'performance-seed names its profiles'
    );

    my $seed = 'GPForum::Command::PerformanceSeed';
    is( _options_of( $seed, qw(--users 7 --profile medium) )->{users},
        $MEDIUM_USERS, 'a --profile after --users wins' );
    is( _options_of( $seed, qw(--profile medium --users 7) )->{profile},
        'custom', 'a number after --profile makes the dataset custom' );
    is( _options_of( $seed, qw(--profile medium --users 7) )->{threads},
        $SMALL_THREADS, 'a custom dataset starts from the small profile' );

    my %readers = (
        'GPForum::Command::Benchmark'          => 'fixture',
        'GPForum::Command::HypnotoadBenchmark' => undef,
        'GPForum::Command::HypnotoadScaling'   => undef,
        'GPForum::Command::QueryPlanEvidence'  => undef,
    );
    for my $class ( sort keys %readers ) {
        my $options = sub (@arguments) {
            return _options_of( $class, @arguments );
        };
        is( $options->( '--profile', 'hot-thread' )->{profile},
            'hot-thread', "$class accepts a seeded profile" );
        if ( defined $readers{$class} ) {
            is( $options->( '--profile', $readers{$class} )->{profile},
                $readers{$class}, "$class accepts $readers{$class}" );
        }
        else {
            _misuse_ok(
                sub { $options->(qw(--profile fixture)) },
                "$class refuses the fixture profile"
            );
        }
        _misuse_ok(
            sub { $options->(qw(--profile huge)) },
            "$class refuses an unknown profile"
        );
    }

    my $scaling = 'GPForum::Command::HypnotoadScaling';
    is_deeply( _options_of( $scaling, qw(--worker-set 2,4) )->{worker_counts},
        [@WORKER_SET], 'hypnotoad-scaling reads a worker set' );
    for my $set ( q{,}, q{}, '2,,4', '0' ) {
        _misuse_ok(
            sub { _options_of( $scaling, '--worker-set', $set ) },
            "hypnotoad-scaling refuses the worker set '$set'"
        );
    }

    my $benchmark = 'GPForum::Command::HypnotoadBenchmark';
    my $proxied   = _options_of( $benchmark, qw(--proxy haproxy) );
    is_deeply(
        [ @{$proxied}{qw(proxy_kind reverse_proxy)} ],
        [ 'haproxy', 1 ],
        '--proxy names the proxy and turns the reverse proxy on'
    );
    my $direct = _options_of( $benchmark, qw(--no-compare) );
    is_deeply(
        [ @{$direct}{qw(compare_in_process compare_direct)} ],
        [ 0, 0 ],
        '--no-compare turns off both comparisons'
    );

    return;
}

# script/bench-outbox-dispatcher croaked its usage, which Perl reports as
# status 255 with " at ... line N." glued on; it now answers misuse like the
# commands do.
sub _test_outbox_benchmark_script {
    my $errors = gensym;
    my $pid    = open3( my $input, my $output, $errors, $EXECUTABLE_NAME,
        'script/bench-outbox-dispatcher', '--bogus' );
    close $input or croak "close child input: $ERRNO";
    my $said = do { local $INPUT_RECORD_SEPARATOR = undef; <$errors> };
    waitpid $pid, 0;

    is( $CHILD_ERROR >> $EXIT_STATUS_SHIFT,
        $EXIT_USAGE, 'the outbox benchmark exits 2 on misuse' );
    like(
        $said,
        qr{\A--bogus[ ]is[ ]not[ ]an[ ]option}msx,
        'saying what was wrong'
    );
    like(
        $said,
        qr{^Usage:[ ]script/bench-outbox-dispatcher[ ]}msx,
        'and prints its usage on stderr'
    );
    unlike( $said, qr/[ ]line[ ][[:digit:]]+/msx, 'without a source location' );

    return;
}

# The options a command reads from a command line, through its private
# parser: the readers are what this test is about.
sub _options_of ( $class, @arguments ) {
    return $class->can('_options')->(@arguments);
}

sub _misuse_ok ( $code, $name ) {
    my $error;
    try {
        $code->();
    }
    catch ($caught) {
        $error = $caught;
    };
    ok( GPForum::X::Usage->caught($error), $name )
      or diag( defined $error ? "$error" : 'nothing was thrown' );

    return;
}

1;
