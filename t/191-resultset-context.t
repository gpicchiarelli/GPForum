# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp       qw(croak);
use English    qw(-no_match_vars);
use File::Find qw(find);
use Test::More;

our $VERSION = '0.001';

# DBIx::Class's search returns a resultset in scalar context and every row in
# list context. Passed as an argument or returned to a caller that happens to
# be in list context, it hands over rows where the code expects a resultset.
# Before subroutine signatures that was silent -- the helper took the first row
# and counted nothing -- and afterwards it died, but only against PostgreSQL,
# because the test doubles return the same object in either context.
# search_rs returns a resultset in every context, so lib/ uses nothing else.
#
# The one allowed ->search( is the forum search service's own API.
my %allowed = ( 'lib/GPForum/Controller/Forum/Search.pm' =>
      qr/gp_search_service->search\s*[(]/msx );

my @violations;
my $examined = 0;
find(
    {
        no_chdir => 1,
        wanted   => sub {
            return if $File::Find::name !~ /[.]pm\z/msx;
            $examined++;
            push @violations, _violations($File::Find::name);
        },
    },
    'lib'
);

cmp_ok( $examined, q{>}, 0, 'the scan examined modules under lib/' );
is_deeply( \@violations, [],
    'lib/ asks DBIx::Class for resultsets with search_rs, never search' )
  or diag join "\n", @violations;

done_testing();

sub _violations {
    my ($path) = @_;

    open my $handle, '<', $path or croak "open $path: $ERRNO";
    my @found;
    while ( my $line = <$handle> ) {
        next if $line                    !~ /->search \s* [(]/msx;
        next if $allowed{$path} && $line =~ $allowed{$path};
        push @found, "$path:$INPUT_LINE_NUMBER: $line";
    }
    close $handle or croak "close $path: $ERRNO";

    return @found;
}

1;
