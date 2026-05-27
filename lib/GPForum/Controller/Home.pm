package GPForum::Controller::Home;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base 'Mojolicious::Controller';

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_SERVER_ERROR => 500;
const my $CATEGORY_LIMIT    => 12;
const my $THREAD_LIMIT      => 20;

sub show {
    my ($self) = @_;

    my $home = eval {
        return $self->gp_home_page_reader->home_page(
            {
                after          => $self->param('after'),
                category_limit => $CATEGORY_LIMIT,
                thread_limit   => $THREAD_LIMIT,
            }
        );
    };

    if ($EVAL_ERROR) {
        $self->app->log->error("home page read failed: $EVAL_ERROR");
        return _render_failure($self);
    }

    return _render_payload(
        $self,
        {
            home    => $home,
            runtime => $self->gp_runtime->as_hash,
        }
    );
}

sub _render_payload {
    my ( $controller, $payload ) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render(
            json   => $payload,
            status => $HTTP_OK,
        );
    }

    return $controller->render(
        template => 'home/index',
        %{$payload},
        status => $HTTP_OK,
    );
}

sub _render_failure {
    my ($controller) = @_;

    my $payload = {
        error  => 'home_unavailable',
        status => 'fail',
    };

    if ( _wants_json($controller) ) {
        return $controller->render(
            json   => $payload,
            status => $HTTP_SERVER_ERROR,
        );
    }

    return $controller->render(
        template => 'home/unavailable',
        %{$payload},
        status => $HTTP_SERVER_ERROR,
    );
}

sub _wants_json {
    my ($controller) = @_;

    my $format = $controller->param('format') || q{};
    return 1 if $format eq 'json';

    my $accept = $controller->req->headers->accept || q{};
    return $accept =~ m{application/json}msx ? 1 : 0;
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

Rendering errors are reported by Mojolicious.

=head1 CONFIGURATION AND ENVIRONMENT

Uses GPForum runtime and forum home page reader helpers configured during
application startup.

=head1 DEPENDENCIES

Uses L<Mojolicious::Controller>.

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
