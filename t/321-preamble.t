# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
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

const my $MINIMUM_FILES => 900;

# The one file allowed code before `use v5.40;`: bin/gpforum, the front door,
# may open with a BEGIN block that finds the supported Perl when an older one
# -- macOS's /usr/bin/perl, 5.34 -- runs it, since that Perl stops at the
# line itself, and the operator read "Perl v5.40.0 required--this is only
# v5.34.1" and no word of which Perl to use. The block asks for the version
# before anything else: its first line tests $OLD_PERL_VERSION against 5.040.
const my %VERSION_GUARDED => ( 'bin/gpforum' => 1 );
const my $VERSION_GUARD   => qr/\A BEGIN [ ] [{]/msx;
const my $VERSION_TEST =>
qr/\A [ ]{4} if [ ] [(] [ ] [\$]OLD_PERL_VERSION [ ] < [ ] 5[.]040 [ ] [)]/msx;

const my @LINE_RULES => (
    [
        'use strict or use warnings' =>
          qr/\A use [ ]+ (?:strict|warnings) [ ]* ;/msx
    ],
    [ 'Try::Tiny' => qr/\A \s* use [ ]+ Try::Tiny \b/msx ],
    [ 'finally'   => qr/\A \s* (?:[}] \s*)? finally \s* [{]/msx ],
);

# The names `use v5.40` imports: builtin's ":5.40" version bundle. indexed is
# one of them; inf, nan, stringify, is_bool, created_as_* and the other
# experimental builtins are not, and a sub may carry their names.
const my @BUILTIN_NAMES => qw(
  blessed ceil false floor indexed is_tainted is_weak refaddr reftype trim true
  unweaken weaken
);

my $builtin = join q{|}, @BUILTIN_NAMES;
my @files   = _perl_files();

is_deeply(
    [ _imported_builtins() ],
    [ sort @BUILTIN_NAMES ],
    'the builtin names are the ones use v5.40 imports'
);
my $guard =
    "package main;\n\nBEGIN {\n"
  . "    if ( \$OLD_PERL_VERSION < 5.040 ) {\n        exit 1;\n    }\n}\n\n"
  . "use v5.40;\n";
is_deeply( [ _code_problems( $guard, $builtin, 'bin/gpforum' ) ],
    [], 'bin/gpforum may find the supported Perl before use v5.40' );
is_deeply(
    [ _code_problems( $guard, $builtin, 'bin/gpforum-migrate' ) ],
    ['code before use v5.40: BEGIN {'],
    'no other file may'
);
is_deeply(
    [
        _code_problems(
            "BEGIN {\n    \$ENV{X} = 1;\n}\n\nuse v5.40;\n", $builtin,
            'bin/gpforum'
        )
    ],
    ['code before use v5.40: BEGIN {'],
    'and bin/gpforum only a block that asks for the version first'
);
is_deeply(
    [
        _code_problems(
            "use v5.40;\n\nsub indexed {\n    return;\n}\n", $builtin
        )
    ],
    ['a sub named like a builtin: indexed'],
    'a sub named indexed is refused'
);

cmp_ok( scalar @files, '>', $MINIMUM_FILES, 'the gate reads the whole tree' );
for my $file (@files) {
    is_deeply( [ _problems( $file, $builtin ) ],
        [], "$file has the v5.40 preamble" );
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

# Which builtins a file declaring `use v5.40` sees under their own names,
# asked of this perl in a child process: under the declaration such a name is
# the lexical alias of the builtin, any other name a sub of the package.
sub _imported_builtins {
    my @candidates = grep { builtin->can($_) } sort keys %builtin::;
    my $probe      = join q{}, "use v5.40;\n",
      map { "print qq{$_\\n} if \\&$_ == \\&builtin::$_;\n" } @candidates;

    open my $child, q{-|}, $EXECUTABLE_NAME, '-e', $probe
      or croak "cannot run $EXECUTABLE_NAME: $OS_ERROR";
    my @imported = <$child>;
    chomp @imported;
    close $child or croak "the builtin probe failed: $CHILD_ERROR";

    return @imported;
}

sub _problems ( $file, $builtin_names ) {
    my ($code) = split /^__END__$/msx, path($file)->slurp, 2;

    return _code_problems( $code, $builtin_names, $file );
}

sub _code_problems ( $code, $builtin_names, $file = q{} ) {
    my @lines    = split /\n/msx, $code;
    my @problems = (
        _preamble_problems( _without_version_guard( $file, @lines ) ),
        _mojo_base_problems(@lines)
    );

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

# The lines of a file without the version guard %VERSION_GUARDED lets it
# open with: its first BEGIN block, when the block tests the version first,
# up to the first closing brace at the start of a line.
sub _without_version_guard ( $file, @lines ) {
    return @lines if !exists $VERSION_GUARDED{$file};

    my ($start) = grep { $lines[$_] =~ $VERSION_GUARD } 0 .. $#lines;
    return @lines
      if !defined $start || ( $lines[ $start + 1 ] // q{} ) !~ $VERSION_TEST;
    my ($end) = grep { $lines[$_] eq '}' } $start .. $#lines;
    return @lines if !defined $end;

    return @lines[ 0 .. $start - 1 ], @lines[ $end + 1 .. $#lines ];
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
