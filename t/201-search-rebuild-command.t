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

use GPForum::Command::SearchRebuild;
use GPForum::Test::SearchRebuildIndexer;

our $VERSION = '0.001';

const my $EXIT_OK    => 0;
const my $EXIT_USAGE => 2;

my $indexer = GPForum::Test::SearchRebuildIndexer->new;

# The operator's way into the search rebuild and lag (ADR 0110): help
# succeeds, misuse is a 2 with the usage before any database is touched, and
# a run reports what it did. What the rebuild does against PostgreSQL is
# t/integration/postgres-search-rebuild.t.
my ( $help, $help_status ) = _run('--help');
is( $help_status, $EXIT_OK, '--help succeeds' );
like(
    $help,
    qr/\A Usage: [ ] bin\/gpforum-search-rebuild/msx,
    'and prints the usage'
);

for my $case (
    [ ['--entity'],                       '--entity without a value' ],
    [ [ '--entity', 'user' ],             'an entity search does not hold' ],
    [ [ '--status', '--entity', 'post' ], '--status with --entity' ],
    [ ['--everything'],                   'an unknown option' ],
  )
{
    my ( $arguments, $label ) = @{$case};
    my ( undef, $status, $errors ) = _run( @{$arguments} );
    is( $status, $EXIT_USAGE, "$label is misuse" );
    like( $errors, qr/Usage:/msx, "$label shows the usage" );
}

my ( $rebuilt, $rebuilt_status ) = _run( '--entity', 'post' );
is( $rebuilt_status,                $EXIT_OK, 'a rebuild succeeds' );
is( $indexer->scope->{entity_type}, 'post',   'for the entity asked' );
is(
    $rebuilt,
    "rebuilt entity_type=post indexed=3 unchanged=5 pruned=1\n",
    'and reports what it indexed, left alone and removed'
);

my ($lag) = _run('--status');
is(
    $lag,
    'search status=behind pending=2 lag_seconds=42'
      . " oldest=2026-09-26T10:00:00Z\n",
    '--status reports the lag'
);

done_testing();

sub _run {
    my (@arguments) = @_;

    my ( $output, $errors, $status ) = ( q{}, q{} );
    {
        open my $stdout, '>', \$output or croak 'failed to capture stdout';
        open my $stderr, '>', \$errors or croak 'failed to capture stderr';
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        $status = GPForum::Command::SearchRebuild->new( indexer => $indexer )
          ->run(@arguments);
        close $stdout or croak 'failed to close stdout capture';
        close $stderr or croak 'failed to close stderr capture';
    }

    return ( $output, $status, $errors );
}

1;
