# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ReplacedSubs;

use v5.40;

use Exporter qw(import);

our $VERSION = '0.001';

our @EXPORT_OK = qw(with_replaced_subs);

# Runs the code with some subs of a package replaced, and puts every one back
# however the code ends. A test uses it on the steps a command names as its
# seams (the hypnotoad benchmark's _start_hypnotoad, _stop_hypnotoad, ...), so
# the replacing is written once instead of a `local *Package::_step = ...` per
# step at each site. `local` empties the glob before the new sub goes in, so
# no "Subroutine redefined" warning has to be silenced.
sub with_replaced_subs ( $package, $replacements, $code ) {
    my %remaining = %{$replacements};
    my ($name) = sort keys %remaining;
    return $code->() if !defined $name;

    my $replacement = delete $remaining{$name};
    no strict 'refs';    ## no critic (TestingAndDebugging::ProhibitNoStrict) -- the glob is named at run time
    local *{"${package}::$name"} = $replacement;

    return with_replaced_subs( $package, \%remaining, $code );
}

1;

__END__

=head1 NAME

GPForum::Test::ReplacedSubs - Run code with some subs of a package replaced.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use GPForum::Test::ReplacedSubs qw(with_replaced_subs);

    with_replaced_subs(
        'GPForum::Command::HypnotoadBenchmark',
        { _start_hypnotoad => sub { return $fake_runtime } },
        sub { $command->benchmark_report($options) },
    );

=head1 DESCRIPTION

Replaces the named subs of a package for as long as a block runs, and
restores them when it returns or dies, for tests that drive a command through
the steps it names as seams.

=head1 SUBROUTINES/METHODS

=head2 with_replaced_subs

Given a package, a hash of sub names to code references and a code reference,
runs the code with those subs replaced and returns what it returns. An
exception the code raises passes through, after the subs are restored.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Exporter>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A replaced name loses its whole glob for the duration, so a package variable
of the same name is hidden too.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
