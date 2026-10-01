# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use Mojo::File qw(path);
use Test::More;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 7;

plan tests => $EXPECTED_TESTS;

my $output = _run_query_plan_check();

like(
    $output,
    qr/query-plan-check [ ] status=ok/msx,
    'query plan check passes'
);

# 26. The gate stopped requiring five indexes migration 037 drops -- it had
# matched migration text rather than the schema the migrations leave behind --
# which left 26; migration 041 added two, for signed-in category pages and the
# profile's thread list (28). Migration 048 drops four partial search indexes,
# three of which the gate required, and adds the one search now takes its
# candidates through, newest first: idx_search_documents_created (quality
# program 8.10). The dropped ones were partial on permission_scope, which no
# statement states, so the planner could never use them.
like( $output, qr/indexes=26/msx,
    'query plan check covers required hot path indexes' );
like( $output, qr/db_evidence=skipped/msx,
    'query plan check skips DB evidence without DSN' );

my $script = path('script/query-plan-check')->slurp;
like( $script, qr/GPFORUM_DATABASE_DSN/msx,
    'query plan check detects configured database DSN' );
like(
    $script,
    qr/--profile', [ ] 'medium'/msx,
    'query plan check uses medium profile for DB-backed evidence'
);

my $ci = path('.github/workflows/ci.yml')->slurp;
like( $ci, qr/script\/query-plan-check/msx, 'CI runs query plan check' );

my $hygiene = path('.github/workflows/project-hygiene.yml')->slurp;
like(
    $hygiene,
    qr/script\/query-plan-check/msx,
    'project hygiene requires query plan check script'
);

sub _run_query_plan_check {
    local %ENV = %ENV;
    delete @ENV{
        qw(
          GPFORUM_DATABASE_DSN
          GPFORUM_DATABASE_USER
          GPFORUM_DATABASE_PASSWORD
        )
    };

    open my $check, q{-|}, 'script/query-plan-check'
      or croak 'failed to run query plan check';

    my $captured = q{};
    while ( my $line = <$check> ) {
        $captured .= $line;
    }

    close $check
      or croak "query plan check failed: $CHILD_ERROR";

    return $captured;
}

1;
