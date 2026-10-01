# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Mojo::File qw(path);
use Test::Mojo;
use Test::More;

use lib 'lib';

our $VERSION = '0.001';

const my $PARITY_DOC => 'docs/ops/console-and-cli.md';

# Quality program 6.5: the console and the shell drifted apart because
# nothing listed one against the other. docs/ops/console-and-cli.md does, and
# this keeps it true: every bin/ command has a row, every row is a command
# that exists, and every console route a row names is one the
# application's router registers. A command without a route says why.
# The application's own router: a route commented out in Routes.pm is not
# registered, which reading the file's text would not notice.
my $routes           = Test::Mojo->new('GPForum')->app->routes;
my $route_registered = sub {
    my ($name) = @_;

    return defined $routes->lookup($name) ? 1 : 0;
};
ok( $route_registered->('admin_dashboard'), 'the router answers by name' );
ok( !$route_registered->('no_such_route'),  'and knows what it lacks' );

my %row_for;
for my $line ( split /\n/msx, path($PARITY_DOC)->slurp ) {
    next if $line !~ /\A [|] \s* `bin\/[^`]+` \s* [|]/msx;

    my ( undef, $command, $console, $notes ) = split /\s* [|] \s*/msx, $line;
    $command =~ s/`//gmsx;
    ok( !exists $row_for{$command}, "$command is listed once" );
    $row_for{$command} = { console => $console, notes => $notes // q{} };
}

my @commands = sort map { 'bin/' . $_->basename } path('bin')->list->each;
ok( scalar @commands, 'bin/ holds commands' );
for my $command (@commands) {
    ok( exists $row_for{$command}, "$command is in $PARITY_DOC" );
}

my %command = map { $_ => 1 } @commands;
for my $command ( sort keys %row_for ) {
    ok( $command{$command}, "$command, listed, exists in bin/" );

    my $row    = $row_for{$command};
    my @routes = $row->{console} =~ /`([^`]+)`/gmsx;
    if ( !@routes ) {
        is( lc $row->{console},
            'none', "$command names a console route or says none" );
        like( $row->{notes}, qr/\w/msx, "$command says why it has none" );
        next;
    }
    for my $route (@routes) {
        ok( $route_registered->($route),
            "the console route $route listed for $command is registered" );
    }
}

done_testing();

1;
