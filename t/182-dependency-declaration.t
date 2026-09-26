# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Module::CoreList;
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

our $VERSION = '0.001';

# A cpanfile that does not describe what the code loads is a supply-chain
# defect, not a style one: the production mailer required Email::Simple while
# the manifest named Email::MIME, so the deployment worked only because a
# transitive dependency happened to install it. See docs/QUALITY_PROGRAM.md 4.2.

const my @SOURCE_TREES => qw(lib bin);

# Loaded through a mechanism a static reader cannot see. Each needs a reason.
const my %ALLOWED_UNDECLARED => ( 'GlifiStore::Client' =>
        'optional L2 cache backend, required at runtime only when '
      . 'glifistore_url is configured; tracked in docs/QUALITY_PROGRAM.md', );

my %provided = _provided_modules();
my @offenders;
for my $module ( sort keys %{ _loaded_modules() } ) {
    next if $module =~ /\A GPForum /msx;
    next if exists $ALLOWED_UNDECLARED{$module};
    next if $provided{$module};
    next if defined Module::CoreList->first_release($module);
    push @offenders, $module;
}

is_deeply( \@offenders, [],
'every module lib/ and bin/ load is core or comes from a locked distribution'
) or diag( 'undeclared: ' . join ', ', @offenders );

# The snapshot only changes when carton reinstalls, so the cpanfile is what
# states intent and is what this asserts on.
my $cpanfile = path('cpanfile')->slurp;
like(
    $cpanfile,
    qr/requires [ ] 'Email::Simple'/msx,
    'the module the identity mailer requires is declared'
);
unlike(
    $cpanfile,
    qr/requires [ ] 'Email::MIME'/msx,
    'the module nothing loads is no longer declared'
);
unlike(
    $cpanfile,
    qr/requires [ ] 'Type::Tiny'/msx,
    'a declared dependency with no call site is gone'
);

done_testing();

# Every module the locked distributions provide, which is the real answer to
# "is this dependency declared" — Mojo::File comes from Mojolicious, not from a
# requires line of its own.
sub _provided_modules {
    my %provided;
    my $in_provides = 0;
    for my $line ( split /\n/msx, path('cpanfile.snapshot')->slurp ) {
        if ( $line =~ /\A \s{4} provides: \s* \z/msx ) {
            $in_provides = 1;
            next;
        }
        if ( $line !~ /\A \s{6} \S/msx ) {
            $in_provides = 0;
            next;
        }
        next              if !$in_provides;
        $provided{$1} = 1 if $line =~ /\A \s+ ([A-Za-z][\w:]*) \s/msx;
    }

    return %provided;
}

sub _loaded_modules {
    my %loaded;
    for my $tree (@SOURCE_TREES) {
        for my $file ( @{ path($tree)->list_tree } ) {
            next
              if $file !~ /[.]pm \z/msx && $file->basename !~ /\A gpforum/msx;
            for my $line ( split /\n/msx, $file->slurp ) {
                next if $line =~ /\A \s* [#]/msx;
                next
                  if $line !~
                  /\A \s* (?:use|require) \s+ ([A-Z][\w:]*) \s* [;(]?/msx;
                $loaded{$1} = 1;
            }
        }
    }

    return \%loaded;
}
