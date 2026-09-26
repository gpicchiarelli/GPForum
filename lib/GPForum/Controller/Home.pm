# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Home;

use strict;
use warnings;

use English qw(-no_match_vars);
use GPForum::Web::HomeAccess;
use Mojo::Base 'Mojolicious::Controller', -signatures;

our $VERSION = '0.001';

sub show ($self) {
    my $access = GPForum::Web::HomeAccess->new;
    my $home   = eval {
        return $self->gp_home_page_reader->home_page(
            {
                %{ $access->query( $self->param('after') ) },
                viewer => $self->gp_forum_viewer,
            }
        );
    };

    if ($EVAL_ERROR) {
        $self->app->log->error("home page read failed: $EVAL_ERROR");
        return $access->render_unavailable($self);
    }

    return $access->render_page( $self,
        $access->page_payload( $home, $self->gp_runtime->as_hash ) );
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

Renders the GPForum public home index.

=head1 SUBROUTINES/METHODS

=head2 show

Renders a navigable SSR home page backed by forum reader services.

=head1 DIAGNOSTICS

Rendering errors are reported by Mojolicious. Reader failures stay logged on
this method and render C<home_unavailable>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses GPForum runtime and forum home page reader helpers configured during
application startup.

=head1 DEPENDENCIES

Uses L<Mojolicious::Controller> and L<GPForum::Web::HomeAccess>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The home page exposes public categories and latest visible public threads. It
does not expose private or moderated content.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
