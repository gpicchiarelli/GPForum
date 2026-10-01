# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp       qw(croak);
use English    qw(-no_match_vars);
use Mojo::File qw(path);
use Pod::Checker;
use Test::More;

our $VERSION = '0.001';

# Quality program, Perl craft: "POD on every public API", gated over the
# service and web layers. 99 of their modules had none on 2026-09-30. Every
# module here carries POD that Pod::Checker accepts, with an =head2 for each
# public sub -- a sub whose name does not start with an underscore, written
# above __END__. "=head2 name (Helper)" documents a helper package's sub.
my @modules = sort map { "$_" }
  map { path($_)->list_tree( { dir => 0 } )->grep(qr/[.]pm\z/msx)->each }
  qw(lib/GPForum/Service lib/GPForum/Web);
ok( scalar @modules, 'the service and web layers hold modules' );

my ( @undocumented, @unchecked, @missing );
for my $module (@modules) {
    my $source = path($module)->slurp;
    my ( $code, $pod ) = split /^__END__$/msx, $source, 2;
    if ( !defined $pod || $pod !~ /^=head1 [ ] NAME/msx ) {
        push @undocumented, $module;
        next;
    }

    my $checker = Pod::Checker->new( -warnings => 1 );
    open my $sink, '>', \my $report or croak "cannot capture: $OS_ERROR";
    $checker->parse_from_file( $module, $sink );
    close $sink or croak "cannot close: $OS_ERROR";
    if ( $checker->num_errors || $checker->num_warnings ) {
        push @unchecked, $module;
    }

    my %documented = map { $_ => 1 } $pod =~ /^=head2 [ ] (\w+)/gmsx;
    for my $sub ( $code =~ /^sub [ ] ([[:lower:]]\w*)/gmsx ) {
        next if $documented{$sub};
        push @missing, "$module: $sub";
    }
}
is_deeply( \@undocumented, [], 'every module has POD' );
is_deeply( \@unchecked,    [], 'which Pod::Checker accepts' );
is_deeply( \@missing,      [], 'with an entry for every public sub' );

done_testing();

1;
