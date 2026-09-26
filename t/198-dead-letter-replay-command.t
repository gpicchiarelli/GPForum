# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::DeadLetterReplay;
use GPForum::Test::UnreachableSchema;

our $VERSION = '0.001';

const my $EXIT_OK    => 0;
const my $EXIT_USAGE => 2;

# The shell side of ADR 0056's replay honours the exit-code contract: help
# succeeds, and every misuse is a 2 with the usage -- before any database is
# touched. What it does against PostgreSQL is
# t/integration/postgres-dead-letter-replay.t.
my ( $help, $help_status ) = _run('--help');
is( $help_status, $EXIT_OK, '--help succeeds' );
like(
    $help,
    qr/\A Usage: [ ] bin\/gpforum-dead-letter-replay/msx,
    'and prints the usage'
);
like( $help, qr/replayed[ ]once/msx, 'including that a replay happens once' );

for my $case (
    [ [],                              'no arguments' ],
    [ ['--id'],                        '--id without a value' ],
    [ [ '--id', '--list' ],            '--id followed by a flag' ],
    [ [ '--list', '--id', 'x' ],       '--list with --id' ],
    [ [ '--list', '--limit', '0' ],    'a zero limit' ],
    [ [ '--list', '--limit', 'lots' ], 'a limit that is not a number' ],
    [ ['--everything'],                'an unknown option' ],
  )
{
    my ( $arguments, $label ) = @{$case};
    my ( undef, $status, $errors ) = _run( @{$arguments} );
    is( $status, $EXIT_USAGE, "$label is misuse" );
    like( $errors, qr/Usage:/msx, "$label shows the usage" );
}

done_testing();

sub _run {
    my (@arguments) = @_;

    my ( $output, $errors ) = ( q{}, q{} );
    open my $stdout, '>', \$output or croak 'failed to capture stdout';
    open my $stderr, '>', \$errors or croak 'failed to capture stderr';
    my $status;
    {
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        $status = GPForum::Command::DeadLetterReplay->new(
            schema => GPForum::Test::UnreachableSchema->new )->run(@arguments);
    }
    close $stdout or croak 'failed to close stdout capture';
    close $stderr or croak 'failed to close stderr capture';

    return ( $output, $status, $errors );
}

1;
