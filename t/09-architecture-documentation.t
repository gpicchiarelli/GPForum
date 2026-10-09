# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Mojo::File qw(path);
use Test::More;

our $VERSION = '0.001';

const my $FIRST_BASELINE_ADR => 49;
const my $LAST_BASELINE_ADR  => 101;
const my $RELATED_SECTION    => 'Related Decisions and Implementation';

# Architecture is maintained in ordinary documentation and ADRs. Behaviour
# belongs to the domain and integration tests; this gate catches missing
# decisions, broken navigation and documentation that points at retired files.
my $index = path('docs/adr/README.md')->slurp;
my @records =
  path('docs/adr')
  ->list->grep( sub { $_->basename =~ /\A [[:digit:]]{4} - .+ [.]md \z/msx } )
  ->each;

subtest 'the architectural baseline is complete and navigable' =>
  \&_check_baseline;
subtest 'the entry documents link to files that exist' => \&_check_links;
subtest 'maintained documents and workflows use the current sources' =>
  \&_check_current_sources;

done_testing();

sub _check_baseline {
    my @missing_references;
    for my $number ( $FIRST_BASELINE_ADR .. $LAST_BASELINE_ADR ) {
        my $id       = sprintf '%04d', $number;
        my @matching = grep { $_->basename =~ /\A \Q$id\E - /msx } @records;
        is( scalar @matching, 1, "ADR $id has one document" );
        next if @matching != 1;

        my $file = $matching[0];
        my $text = $file->slurp;
        like(
            $text,
            qr/\A [#] [ ] ADR [ ] \Q$id\E : [ ] \S/msx,
            "ADR $id has its own title"
        );
        my @sections =
          ( qw(Status Context Decision Consequences), $RELATED_SECTION );
        my @missing =
          grep { $text !~ /^[#]{2} [ ] \Q$_\E \n+ \S/msx } @sections;
        is_deeply( \@missing, [], "ADR $id has the required sections" );

        my $name = $file->basename;
        like(
            $index,
            qr/[[]\Q$id\E[]][(]\Q$name\E[)]/msx,
            "ADR $id is linked from the index"
        );

        my ( undef, $related ) =
          split /^ [#]{2} [ ] \Q$RELATED_SECTION\E \n/msx,
          $text, 2;
        for my $reference ( ( $related // q{} ) =~
            /`((?:t|docs|script|lib|bin|deploy|etc)\/[^`\s]+)`/gmsx )
        {
            $reference =~ s/[#].*\z//msx;
            next if $reference =~ /[*{}]/msx;
            if ( !-e $reference ) {
                push @missing_references, "$name: $reference";
            }
        }
    }
    is_deeply( \@missing_references, [],
        'implementation references point to existing tests and artifacts' );
    return undef;
}

sub _check_links {
    for my $name (
        qw(README.md ARCHITECTURE.md GOVERNANCE.md CONTRIBUTING.md ROADMAP.md
        docs/README.md docs/CI.md docs/adr/README.md)
      )
    {
        my $file = path($name);
        my @missing;
        for my $target ( $file->slurp =~ /[[][^]]+[]][(]([^)\s]+)[)]/gmsx ) {
            next if $target =~ /\A (?: [[:alpha:]][\w+.-]*: | [#] )/msx;
            $target =~ s/[#?].*\z//msx;
            if ( !-e $file->dirname->child($target) ) {
                push @missing, $target;
            }
        }
        is_deeply( \@missing, [], "$name links to existing local files" );
    }
    return undef;
}

sub _check_current_sources {
    my @files = map { path($_) }
      qw(README.md ARCHITECTURE.md GOVERNANCE.md CONTRIBUTING.md ROADMAP.md CHANGELOG.md
      index.html .gitleaks.toml etc/cpan-audit-ignore.txt);
    push @files, path('docs')->list_tree->grep(
        sub {
            $_->basename =~ /[.]md \z/msx
              && $_->to_string !~ m{\A docs/ops/evidence/}msx;
        }
    )->each;
    push @files,
      path('.github')
      ->list_tree->grep( sub { $_->basename =~ /[.](?:yml|md) \z/msx } )->each;

    my @obsolete;
    for my $file (@files) {
        if ( $file->slurp =~
m{\b prompt/ | 09-prompt-alignment[.]t | Prompt [ ] \d+ [ ] alignment}msx
          )
        {
            push @obsolete, $file->to_string;
        }
    }
    is_deeply( \@obsolete, [],
        'maintained sources contain no retired documentation references' );
    ok( !-d 'prompt', 'there is one architectural documentation source' );
    return undef;
}

1;
