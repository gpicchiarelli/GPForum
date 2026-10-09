# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Mojo::File qw(path);
use Test::More;

our $VERSION = '0.001';

# Walkthrough 2, friction 10: README and DEPLOYMENT typed `gpforum VERB`,
# but seven runbooks, docs/MVP.md and docs/OUTBOX_LIFECYCLE.md still typed
# `script/gpforum-carton exec bin/gpforum-...` or `... exec perl -Ilib
# bin/gpforum ...`, and DEPLOYMENT offered GPFORUM_CARTON in the environment
# file. An operator types the verb; the old names are for the units and
# for scripts. A path under a code directory -- the crontab's
# /usr/local/www/gpforum/script/gpforum-carton exec -- is a service file's
# line, shown as it is installed, not a command to type.

const my $CARTON_EXEC =>
  qr{(?<![\w/.]) script/gpforum-carton [ ]+ exec [ ]+}msx;
const my $ENTRYPOINT => qr{(?: perl [ ]+ -Ilib [ ]+ )? bin/gpforum}msx;
const my $MINIMUM    => 10;

my @guides = (
    'README.md', 'docs/DEPLOYMENT.md', 'docs/MVP.md',
    'docs/OUTBOX_LIFECYCLE.md',
    sort map { "$_" } path('docs/ops')->list->grep(qr/[.]md\z/msx)->each,
);
cmp_ok( scalar @guides, '>', $MINIMUM, 'the guides and the runbooks are read' );

for my $guide (@guides) {
    my @typed = grep { /$CARTON_EXEC$ENTRYPOINT/msx } split /\n/msx,
      path($guide)->slurp;
    is_deeply( \@typed, [], "$guide types gpforum VERB" );
}

unlike( path('docs/DEPLOYMENT.md')->slurp,
    qr/GPFORUM_CARTON/msx,
    'and DEPLOYMENT puts nothing about Carton in the environment file' );

done_testing();

1;
