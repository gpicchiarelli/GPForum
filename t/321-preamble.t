# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use List::Util qw(any);
use Mojo::File qw(path);
use Test::More;

our $VERSION = '0.001';

# Every Perl file starts from the same line (ADR 0117): `use v5.40;` gives
# strict, warnings, signatures and try/catch, and turns off indirect object
# syntax, bareword filehandles, multidimensional hash keys and switch.
#
# - Mojo::Base imports the :5.16 feature bundle, which turns those four back
#   on for the rest of the scope. Only a `use v5.40;` after it resets them, so
#   it must be the line after every `use Mojo::Base`, inner packages too.
# - `use strict` and `use warnings` are implied, and a file still carrying
#   them was never converted.
# - Try::Tiny's `try` is a syntax error once the try feature is on.
# - `use v5.40` imports trim, blessed, true, false, ceil, floor and the other
#   5.40 builtins lexically: a package sub of one of those names is redefined
#   and can no longer be found as a method.
# - `finally` is still experimental in 5.40: it is never used.

# TODO (WP8): files that were being edited by other sessions when the preamble sweep ran
# (WP1, 2026-10-03). They are converted once their owners have committed, and
# leave this list then; a listed file that already passes fails the test, so
# the list cannot outlive its reason.
const my @UNCONVERTED => qw(
  lib/GPForum/Controller/Health.pm
  lib/GPForum/Controller/Operations.pm
  lib/GPForum/Service/Forum/PostReader.pm
  lib/GPForum/Service/Operations/StagingHostVerify.pm
  lib/GPForum/ViewModel/Base.pm
  lib/GPForum/ViewModel/Forum/Rows.pm
  lib/GPForum/Web/HealthPayload.pm
  lib/GPForum/Web/OperationsAccess.pm
  t/138-web-operations-access.t
  t/188-theme-contrast.t
  t/300-health-report-access.t
  t/320-thread-page-reading-first.t
  t/67-ui-system.t
  t/77-web-technical-payloads.t
  t/integration/postgres-health-access.t
  t/lib/GPForum/Test/DegradedReadiness.pm
  t/lib/GPForum/Test/ForumWebServices.pm
);

const my $MINIMUM_FILES => 900;

const my @LINE_RULES => (
    [
        'use strict or use warnings' =>
          qr/\A use [ ]+ (?:strict|warnings) [ ]* ;/msx
    ],
    [ 'Try::Tiny' => qr/\A \s* use [ ]+ Try::Tiny \b/msx ],
    [ 'finally'   => qr/\A \s* (?:[}] \s*)? finally \s* [{]/msx ],
);

const my @BUILTIN_NAMES => qw(
  blessed ceil created_as_number created_as_string false floor inf is_tainted
  is_weak nan refaddr reftype stringify trim true unweaken weaken
);

my %unconverted = map { $_ => 1 } @UNCONVERTED;
my $builtin     = join q{|}, @BUILTIN_NAMES;
my @files       = _perl_files();

cmp_ok( scalar @files, '>', $MINIMUM_FILES, 'the gate reads the whole tree' );
for my $file (@UNCONVERTED) {
    ok( -f $file, "$file, listed as unconverted, exists" );
}

for my $file (@files) {
    my @problems = _problems( $file, $builtin );
    if ( $unconverted{$file} ) {
        ok( scalar @problems,
            "$file is listed as unconverted, so it must not pass yet" )
          or diag("$file passes: remove it from \@UNCONVERTED");
        next;
    }
    is_deeply( \@problems, [], "$file has the v5.40 preamble" );
}

done_testing();

# The files script/perlcritic and script/perltidy-check read: bin/, every .pm,
# .pl and .t under lib/ and t/, and the programs in script/ whose first line
# names perl.
sub _perl_files {
    my @found;
    for my $root (qw(bin lib t)) {
        push @found, grep { m{\A bin/}msx || /[.](?:pm|pl|t)\z/msx }
          map { "$_" } path($root)->list_tree->each;
    }
    for my $candidate ( path('script')->list->each ) {
        my ($first) = split /\n/msx, $candidate->slurp, 2;
        if ( defined $first && $first =~ /perl/msx ) {
            push @found, "$candidate";
        }
    }

    my @sorted = sort @found;

    return @sorted;
}

sub _problems ( $file, $builtin_names ) {
    my ($code)   = split /^__END__$/msx, path($file)->slurp, 2;
    my @lines    = split /\n/msx, $code;
    my @problems = ( _preamble_problems(@lines), _mojo_base_problems(@lines) );

    for my $rule (@LINE_RULES) {
        my ( $problem, $pattern ) = @{$rule};
        if ( any { /$pattern/msx } @lines ) {
            push @problems, $problem;
        }
    }
    if ( $code =~ /^ \s* sub [ ]+ ($builtin_names) \b/msx ) {
        push @problems, "a sub named like a builtin: $1";
    }

    return @problems;
}

# Only comments, blank lines, package lines and use lines (with their
# continuation lines) may come before `use v5.40;`: anything else runs
# without strictures.
sub _preamble_problems (@lines) {
    for my $line (@lines) {
        if ( $line eq 'use v5.40;' ) {
            return ();
        }
        if ( $line !~ /\A (?: \s | [#)] | package [ ] | use [ ] | \z )/msx ) {
            return ("code before use v5.40: $line");
        }
    }

    return ('no use v5.40');
}

sub _mojo_base_problems (@lines) {
    my @problems;
    for my $index ( grep { $lines[$_] =~ /\A use [ ]+ Mojo::Base \b/msx }
        0 .. $#lines )
    {
        my $next = $lines[ $index + 1 ] // q{};
        if ( $next ne 'use v5.40;' ) {
            push @problems,
                'use Mojo::Base on line '
              . ( $index + 1 )
              . ' is not followed by use v5.40';
        }
    }

    return @problems;
}

1;
