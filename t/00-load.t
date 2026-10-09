# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Mojo::File qw(path);
use Test::More;

use lib 'lib';
use lib 't/lib';

our $VERSION = '0.001';

# Every module under lib/ loads. They are found on disk, not listed: the list
# this test kept fell 100 modules behind -- GPForum::Benchmark::Measure, the
# CLI adapters, most Command and OS modules, Controller::Base,
# Web::SecurityEvent -- and nothing noticed, since a module nobody listed was
# never loaded. The shared test doubles below are loaded too, because several
# tests build on each of them.
const my @SHARED_DOUBLES => qw(
  GPForum::Test::MigrationDbh
  GPForum::Test::MigrationStorage
  GPForum::Test::MigrationSchema
  GPForum::Test::AdminWebServices
  GPForum::Test::IdentitySecurityAudit
  GPForum::Test::SharedCacheClient
  GPForum::Test::ResponderController
  GPForum::Test::DiscoveryController
  GPForum::Test::QueryBudgetResultSet
  GPForum::Test::QueryBudgetSchema
);

# Fewer than this means the search ran somewhere else, not that lib/ shrank.
const my $MINIMUM_MODULES => 400;

my @modules = _lib_modules();
cmp_ok( scalar @modules,
    '>', $MINIMUM_MODULES, 'the modules under lib/ are found' );
for my $module ( @modules, @SHARED_DOUBLES ) {
    use_ok($module);
}

done_testing();

sub _lib_modules {
    my @names = map { s{\A lib/}{}msxr =~ s{[.]pm\z}{}msxr =~ s{/}{::}gmsxr }
      grep { /[.]pm\z/msx } map { "$_" } path('lib')->list_tree->each;
    my @sorted = sort @names;

    return @sorted;
}

1;
