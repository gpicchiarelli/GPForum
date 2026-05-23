package GPForum::Controller::Home;

use strict;
use warnings;

use Mojo::Base 'Mojolicious::Controller';

our $VERSION = '0.001';

sub show {
    my ($self) = @_;

    return $self->render(
        template => 'home/index',
        runtime  => $self->gp_runtime->as_hash,
    );
}

1;

__END__

=head1 NAME

GPForum::Controller::Home - Home page controller.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->get(q{/})->to('Home#show');

=head1 DESCRIPTION

Renders the initial GPForum application home page.

=head1 SUBROUTINES/METHODS

=head2 show

Renders the home page.

=head1 DIAGNOSTICS

Rendering errors are reported by Mojolicious.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the GPForum runtime helper configured during application startup.

=head1 DEPENDENCIES

Uses L<Mojolicious::Controller>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The home page is a milestone-zero status surface.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
