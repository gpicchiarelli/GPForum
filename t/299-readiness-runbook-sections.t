# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::Service::Operations::Readiness;

our $VERSION = '0.001';

# A readiness check that is not ok carries its runbook, and a runbook may name
# a section of its file: docs/PERFORMANCE.md#query-budgets, say. t/33 holds
# every runbook to being a file; this holds every section to being a heading
# in it, so renaming a heading, or merging the document it was in into
# another, cannot leave /health/ready pointing at nothing. The anchors are
# the ones GitHub renders: the heading in lower case, without punctuation,
# its spaces made hyphens.
my $runbooks = GPForum::Service::Operations::Readiness->runbooks;
my @sections = grep { $runbooks->{$_} =~ /[#]/msx } sort keys %{$runbooks};

ok( scalar @sections, 'some runbooks name a section of their file' );
for my $check (@sections) {
    my ( $file, $section ) = split /[#]/msx, $runbooks->{$check}, 2;
    ok( _anchors($file)->{$section},
        "the $check runbook's section $section is a heading in $file" );
}

done_testing();

# The anchors of a Markdown file's headings, outside fenced code. None for a
# file that is not there: t/33 says so.
sub _anchors {
    my ($file) = @_;

    my %anchor;
    return \%anchor if !-f $file;

    my $fenced = 0;
    for my $line ( split /\n/msx, path($file)->slurp('UTF-8') ) {
        if ( $line =~ /\A [`]{3}/msx ) {
            $fenced = !$fenced;
            next;
        }
        next if $fenced;

        my ($heading) = $line =~ /\A [#]+ [ ]+ (.+?) [ ]* \z/msx;
        next if !defined $heading;

        my $anchor = lc $heading;
        $anchor =~ s/[^\w\s-]//gmsx;
        $anchor =~ s/\s/-/gmsx;
        $anchor{$anchor} = 1;
    }

    return \%anchor;
}

1;
