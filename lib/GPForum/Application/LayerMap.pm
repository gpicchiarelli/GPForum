# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Application::LayerMap;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

# The layers GPForum is built from, lowest first, named by the namespaces that
# hold the code. A module may depend on its own layer and the layers below it,
# never on one above. t/192-layering.t holds every module in lib/ to that, and
# fails on a module whose namespace is not listed here, so a new namespace is
# placed before it can land. ADR 0107 records why these are the layers.
const my @LAYERS => (
    {
        name       => 'foundation',
        root       => 0,
        purpose    => 'configuration, persistence and cross-cutting contracts',
        namespaces => [
            qw(Config Log Runtime OS Domain Jobs Schema Migration
              Infrastructure)
        ],
    },
    {
        name       => 'service',
        root       => 0,
        purpose    => 'the application: rules, workflows, readers and stores',
        namespaces => [qw(Service)],
    },
    {
        name       => 'presentation',
        root       => 0,
        purpose    => 'turning service results into pages and headers',
        namespaces => [qw(Web ViewModel View Theme Security I18N)],
    },
    {
        name       => 'adapter',
        root       => 0,
        purpose    => 'the ways in: HTTP, the command line and jobs',
        namespaces => [qw(Controller Command Worker Benchmark)],
    },
    {
        name       => 'composition',
        purpose    => 'wiring the others together',
        namespaces => [qw(Bootstrap CLI Application)],
        root       => 1,
    },
);

sub layers ($self) {
    my $rank = 0;

    return [
        map {
            {
                name       => $_->{name},
                purpose    => $_->{purpose},
                rank       => $rank++,
                namespaces => [ map { "GPForum::$_" } @{ $_->{namespaces} } ],
            }
        } @LAYERS
    ];
}

# The layer a module belongs to, by the first segment after GPForum::. The
# application class GPForum itself is the composition root. Undef for a module
# outside every layer.
sub layer_of ( $self, $module ) {
    my ($segment) = $module =~ /\A GPForum (?: :: (\w+) )? (?: :: | \z)/msx;
    return if $module !~ /\A GPForum (?: :: | \z)/msx;

    my $rank = 0;
    for my $layer (@LAYERS) {
        my %member = map { $_ => 1 } @{ $layer->{namespaces} };
        if ( defined $segment ? $member{$segment} : $layer->{root} ) {
            return { name => $layer->{name}, rank => $rank };
        }
        $rank++;
    }

    return;
}

sub may_depend ( $self, $from, $to ) {
    my $from_layer = $self->layer_of($from);
    my $to_layer   = $self->layer_of($to);
    return 0 if !$from_layer || !$to_layer;

    return $to_layer->{rank} <= $from_layer->{rank} ? 1 : 0;
}

1;

__END__

=head1 NAME

GPForum::Application::LayerMap - The layers GPForum is built from.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $map = GPForum::Application::LayerMap->new;
    $map->layer_of('GPForum::Service::Forum::PostStore')->{name};   # service
    $map->may_depend( 'GPForum::Service::Search::Searcher',
        'GPForum::Command::Migrate' );                                # 0

=head1 DESCRIPTION

Declares the five layers, lowest first -- foundation, service, presentation,
adapter, composition -- and the namespaces each holds. A module may depend on
its own layer and those below it. C<t/192-layering.t> enforces the rule over
every module in C<lib/>; ADR 0107 records the decision.

=head1 SUBROUTINES/METHODS

=head2 layers

The layers, lowest first, each with C<name>, C<purpose>, C<rank> and its
C<namespaces>.

=head2 layer_of

The layer, as C<name> and C<rank>, a module belongs to; undef for a module in
no layer.

=head2 may_depend

True when the first module may depend on the second: both are in a layer and
the second's layer is not above the first's.

=head1 DIAGNOSTICS

None; unknown modules are reported by returning undef or false.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Placement is by top-level namespace, so a module that belongs in another layer
has to move to that layer's namespace rather than be listed as an exception.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
