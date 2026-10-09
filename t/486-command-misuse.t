# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::AdminBootstrap;
use GPForum::Command::Migrate;
use GPForum::Command::Usage;

our $VERSION = '0.001';

const my $EXIT_USAGE => 2;
const my $USAGE      => "Usage: bin/gpforum-x [--limit N]\n";

# B6: misuse always says what was wrong, once, before the usage; and through
# the front door the usage names the verb the operator typed.

subtest 'the shared parser says which option it did not know' => sub {
    my $table = {
        numbers  => { '--limit' => [ limit => 'positive_integer' ] },
        switches => { '--json'  => { json => 1 } },
        usage    => $USAGE,
    };
    for my $case (
        [ ['--bogus'], qr/\A --bogus [ ] is [ ] not [ ] an [ ] option/msx ],
        [ [ '--limit', 'ten' ], qr/above [ ] zero, [ ] not [ ] 'ten'/msx ],
        [ ['--limit'], qr/\A --limit [ ] takes [ ] a [ ] whole [ ] number/msx ],
      )
    {
        my ( $arguments, $reason ) = @{$case};
        my $error = _refusal(
            sub {
                GPForum::Command::Usage->parse_options( $arguments, {},
                    $table );
            }
        );
        ok( GPForum::Command::Usage->is_usage($error),
            "@{$arguments} is misuse" );
        like( "$error", $reason,            'and says what was wrong' );
        like( "$error", qr/\n\nUsage: /msx, 'before the usage' );
    }
    my $choice = _refusal(
        sub {
            GPForum::Command::Usage->option_choice( 'huge', [qw(small medium)],
                $USAGE, '--profile' );
        }
    );
    like(
        "$choice",
        qr/of [ ] small, [ ] medium, [ ] not [ ] 'huge'/msx,
        'a choice lists what it takes'
    );
};

subtest 'a usage error prints the usage once' => sub {
    my ( $status, $errors ) = _stderr(
        sub {
            GPForum::Command::Usage->error( "--bogus is wrong\n\n$USAGE",
                $USAGE );
        }
    );
    is( $status, $EXIT_USAGE, 'misuse is 2' );
    my @usages = $errors =~ /^Usage:/gmsx;
    is( scalar @usages, 1, 'with the usage once, not twice' );
    like( $errors, qr/\A --bogus [ ] is [ ] wrong/msx, 'after the reason' );
};

subtest 'through the front door, usage names the verb typed' => sub {
    local $PROGRAM_NAME = 'gpforum partitions';
    my ( undef, $errors ) = _stderr(
        sub {
            GPForum::Command::Usage->error( 'no such thing',
                "Usage: bin/gpforum-partition-maintenance [--plan]\n" );
        }
    );
    like(
        $errors,
        qr/^Usage: [ ] gpforum [ ] partitions [ ] \[--plan\]/msx,
        'bin/gpforum-partition-maintenance reads gpforum partitions'
    );

    local $PROGRAM_NAME = 'bin/gpforum-partition-maintenance';
    ( undef, $errors ) = _stderr(
        sub {
            GPForum::Command::Usage->error( 'no such thing',
                "Usage: bin/gpforum-partition-maintenance [--plan]\n" );
        }
    );
    like(
        $errors,
        qr{^Usage: [ ] bin/gpforum-partition-maintenance}msx,
        'and the entrypoint keeps its own name'
    );
};

subtest 'admin says what was wrong with its command line' => sub {
    for my $case (
        [ [],          qr/\A Say [ ] what [ ] to [ ] do/msx ],
        [ ['promote'], qr/\A 'promote' [ ] is [ ] not [ ] something/msx ],
        [
            ['create'],
            qr/\A gpforum [ ] admin [ ] create [ ] needs [ ] --email/msx
        ],
        [
            [ 'create', '--email', 'you@example.com' ],
            qr/needs [ ] --username/msx
        ],
        [
            [ 'create', '--email' ],
            qr/\A --email [ ] needs [ ] a [ ] value/msx
        ],
        [ ['grant'],                            qr/\A Say [ ] whom/msx ],
        [ [ 'grant', 'you', '--user-id', 'x' ], qr/one [ ] of [ ] them/msx ],
        [
            [ '--user-id', 'x', '--bogus' ],
            qr/\A --bogus [ ] is [ ] not [ ] an [ ] option/msx
        ],
      )
    {
        my ( $arguments, $reason ) = @{$case};
        my ( $status,    $errors ) = _stderr(
            sub { GPForum::Command::AdminBootstrap->new->run( @{$arguments} ) }
        );
        is( $status, $EXIT_USAGE, "admin @{$arguments} is misuse" );
        like( $errors, $reason, 'saying what was wrong' );
        my @usages = $errors =~ /^Usage:/gmsx;
        is( scalar @usages, 1, 'with the usage once' );
    }
};

subtest 'migrate too' => sub {
    for my $case (
        [ ['--aply'], qr/\A --aply [ ] is [ ] not [ ] an [ ] option/msx ],
        [ [ '--plan',  '--apply' ],         qr/\A Choose [ ] one [ ] of/msx ],
        [ [ '--check', '--no-partitions' ], qr/goes [ ] with [ ] applying/msx ],
      )
    {
        my ( $arguments, $reason ) = @{$case};
        my ( $status,    $errors ) = _stderr(
            sub { GPForum::Command::Migrate->new->run( @{$arguments} ) } );
        is( $status, $EXIT_USAGE, "migrate @{$arguments} is misuse" );
        like( $errors, $reason, 'saying what was wrong' );
    }
};

done_testing();

sub _refusal ($code) {
    try {
        $code->();
    }
    catch ($error) {
        return $error;
    };

    return undef;
}

sub _stderr ($code) {
    my $errors = q{};
    open my $capture, '>', \$errors or croak 'capture stderr';
    my $status;
    {
        local *STDERR = $capture;
        $status = $code->();
    }
    close $capture or croak 'close stderr';

    return ( $status, $errors );
}

1;
