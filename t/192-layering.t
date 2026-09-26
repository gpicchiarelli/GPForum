# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use File::Find qw(find);
use Test::More;

use lib 'lib';

use GPForum::Application::LayerMap;

our $VERSION = '0.001';

# A dependency is a use or require, a Mojo::Base / parent / base superclass,
# or a Class->method call.
const my @DEPENDENCY_PATTERNS => (
    qr/\b (?:use|require) \s+ (GPForum (?:::\w+)*)/msx,
    qr/\b use \s+ (?:Mojo::Base|parent|base) \s+ ['"] (GPForum (?:::\w+)*)/msx,
    qr/\b (GPForum (?:::\w+)+) \s* ->/msx,
);
const my $HEREDOC_START => qr/<< ~? (["']?) ([[:upper:]_]\w*) \1/msx;

# ADR 0107: the layers are the namespaces that hold the code, lowest first --
# foundation, service, presentation, adapter, composition -- and a module may
# depend on its own layer and those below it. Declared in LayerMap, enforced
# here over every module in lib/. Before this, the declared layer map named
# namespaces that held two modules, and four dependencies pointed up: a
# service running CLI commands, a service using a worker's module, and the
# event recorder -- infrastructure -- reaching into two services.
my $map = GPForum::Application::LayerMap->new;

my %file_for;
find(
    {
        no_chdir => 1,
        wanted   => sub {
            return if $File::Find::name        !~ /[.]pm\z/msx;
            ( my $module = $File::Find::name ) =~ s{\A lib/ | [.]pm \z}{}gmsx;
            $module                            =~ s{/}{::}gmsx;
            $file_for{$module} = $File::Find::name;
        },
    },
    'lib/GPForum',
);
$file_for{GPForum} = 'lib/GPForum.pm';

my ( @unplaced, @upward );
my $edges = 0;
for my $module ( sort keys %file_for ) {
    if ( !$map->layer_of($module) ) {
        push @unplaced, $module;
        next;
    }
    for my $target ( _dependencies( $file_for{$module} ) ) {
        next if $target eq $module;
        $edges++;
        next if $map->may_depend( $module, $target );
        push @upward, _describe( $module, $target );
    }
}

cmp_ok( scalar keys %file_for, q{>}, 0, 'the scan examined the modules' );
cmp_ok( $edges, q{>}, 0, 'and found the dependencies between them' );
is_deeply( \@unplaced, [], 'every module in lib/ belongs to a layer' )
  or diag join "\n", @unplaced;
is_deeply( \@upward, [], 'no module depends on a layer above its own' )
  or diag join "\n", @upward;

# The rule would have caught each of the four that existed.
for my $case (
    [
        'GPForum::Service::Operations::StagingDrill',
        'GPForum::Command::Migrate'
    ],
    [ 'GPForum::Service::Outbox::DomainEventTransport', 'GPForum::Worker::X' ],
    [ 'GPForum::Infrastructure::EventRecorder', 'GPForum::Service::Id' ],
  )
{
    ok( !$map->may_depend( @{$case} ), "$case->[0] may not use $case->[1]" );
}

done_testing();

# Every GPForum module a file depends on, sorted.
sub _dependencies {
    my ($path) = @_;

    my %found;
    for my $line ( _code_lines($path) ) {
        for my $pattern (@DEPENDENCY_PATTERNS) {
            while ( $line =~ /$pattern/gmsx ) {
                $found{$1} = 1;
            }
        }
    }

    my @modules = sort keys %found;
    return @modules;
}

# The lines of a module that are code: POD, comments, everything after
# __END__, and heredoc bodies -- text a module writes out, such as the
# application file HypnotoadBenchmark generates -- are left out.
sub _code_lines {
    my ($path) = @_;

    open my $handle, '<', $path or croak "open $path: $ERRNO";
    my @lines = <$handle>;
    close $handle or croak "close $path: $ERRNO";

    my ( @code, $in_pod, $heredoc );
    for my $line (@lines) {
        if ( defined $heredoc ) {
            if ( $line =~ /\A \s* \Q$heredoc\E \s* \z/msx ) {
                undef $heredoc;
            }
            next;
        }
        last if $line =~ /\A __ (?:END|DATA) __/msx;
        if ( $line =~ /\A =(\w+)/msx ) {
            $in_pod = $1 ne 'cut';
            next;
        }
        next if $in_pod || $line =~ /\A \s* [#]/msx;
        if ( $line =~ $HEREDOC_START ) {
            $heredoc = $2;
        }
        push @code, $line;
    }

    return @code;
}

sub _describe {
    my ( $module, $target ) = @_;

    my $from = $map->layer_of($module);
    my $to   = $map->layer_of($target);

    return
      "$module ($from->{name}) -> $target ("
      . ( $to ? $to->{name} : 'no layer' ) . ')';
}

1;
