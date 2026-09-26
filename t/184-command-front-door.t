# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum;
use GPForum::Command::Usage;

our $VERSION = '0.001';

const my $EXIT_OK      => 0;
const my $EXIT_FAILURE => 1;
const my $EXIT_USAGE   => 2;

# system() keeps the exit status in the high byte.
const my $EXIT_STATUS_SHIFT => 8;

# bin/gpforum started Mojolicious::Commands without registering a namespace,
# so it listed the framework's own commands and none of this project's.
my $app        = GPForum->new;
my @namespaces = @{ $app->commands->namespaces };

is( $namespaces[0], 'GPForum::CLI',
    'the project command namespace is registered first' );
ok(
    !( grep { $_ eq 'Mojolicious::Command::Author' } @namespaces ),
    'the author namespace is not offered to operators'
);

# Every GPForum::Command::* except the Usage helper must be reachable by name.
opendir my $dir, 'lib/GPForum/Command' or croak "opendir: $ERRNO";
my @commands =
  sort grep { $_ ne 'Usage' }
  map { s/[.]pm\z//msxr } grep { /[.]pm\z/msx } readdir $dir;
closedir $dir or croak "closedir: $ERRNO";

opendir my $cli, 'lib/GPForum/CLI' or croak "opendir: $ERRNO";
my @adapters = sort map { s/[.]pm\z//msxr } grep { /[.]pm\z/msx } readdir $cli;
closedir $cli or croak "closedir: $ERRNO";

is(
    scalar @adapters,
    scalar @commands,
    'every command has a front-door adapter'
);

for my $adapter (@adapters) {
    my $class = "GPForum::CLI::$adapter";
    ## no critic (Modules::RequireBarewordIncludes)
    # The adapter set is discovered from the directory, so the name is only
    # known at run time; a bareword cannot express that.
    require 'GPForum/CLI/' . $adapter . '.pm';
    ## use critic
    my $command = $class->new;
    ok( length $command->description, "$adapter has a description" );
    like( $command->usage, qr/Usage:/msx, "$adapter reports its usage" );
}

# The exit-code contract the entrypoints share.
is( GPForum::Command::Usage->help( \*STDOUT, q{} ), $EXIT_OK, 'help succeeds' );
ok( GPForum::Command::Usage->is_usage('Usage: bin/x'),
    'a usage message is recognised' );
ok(
    !GPForum::Command::Usage->is_usage('database is down'),
    'a real failure is not mistaken for misuse'
);
is(
    GPForum::Command::Usage->trimmed('Usage: bin/x at bin/x line 17.'),
    'Usage: bin/x',
    'croak location is stripped from operator text'
);
isnt( $EXIT_USAGE, $EXIT_FAILURE, 'misuse and failure are distinguishable' );

# And the front door keeps it: Mojolicious ignores a command's return value,
# so misuse through bin/gpforum exited 0.
my $status = system {$EXECUTABLE_NAME} $EXECUTABLE_NAME, '-Ilib', 'bin/gpforum',
  'search_rebuild', '--entity', 'bogus';
is( $status >> $EXIT_STATUS_SHIFT,
    $EXIT_USAGE, 'bin/gpforum exits 2 on misuse, as the command does' );

done_testing();

1;
