package GPForum::Web::HomeAccess;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Web::Responder;

our $VERSION = '0.001';

const my $HTTP_OK              => 200;
const my $HTTP_SERVER_ERROR    => 500;
const my $CATEGORY_LIMIT       => 12;
const my $THREAD_LIMIT         => 20;
const my $INDEX_TEMPLATE       => 'home/index';
const my $UNAVAILABLE_TEMPLATE => 'home/unavailable';

sub query {
    my ( undef, $after ) = @_;

    return {
        after          => $after,
        category_limit => $CATEGORY_LIMIT,
        thread_limit   => $THREAD_LIMIT,
    };
}

sub page_payload {
    my ( undef, $home, $runtime ) = @_;

    return {
        home    => $home,
        runtime => $runtime,
    };
}

sub failure_payload {
    return {
        error  => 'home_unavailable',
        status => 'fail',
    };
}

sub render_page {
    my ( undef, $controller, $payload ) = @_;

    return GPForum::Web::Responder->new->payload(
        {
            controller => $controller,
            payload    => $payload,
            status     => $HTTP_OK,
            template   => $INDEX_TEMPLATE,
        }
    );
}

sub render_unavailable {
    my ( $self, $controller ) = @_;

    return GPForum::Web::Responder->new->error(
        {
            controller => $controller,
            payload    => $self->failure_payload,
            status     => $HTTP_SERVER_ERROR,
            template   => $UNAVAILABLE_TEMPLATE,
        }
    );
}

1;

__END__

=head1 NAME

GPForum::Web::HomeAccess - Home page query and render contracts.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $query = $access->query( $controller->param('after') );
    return $access->render_unavailable($controller);

=head1 DESCRIPTION

Owns home reader limits, the success payload shape, and the custom
C<home_unavailable> 500 contract. It does not read the forum store.
L<GPForum::Controller::Home> still evaluates the home-page reader and logs
failures. This is not L<GPForum::Web::Guard>: the unavailable page keeps its
own error code and template.

=head1 SUBROUTINES/METHODS

=head2 query

Returns the home-page reader input, including category and thread limits.

=head2 page_payload

Returns the success hash with C<home> and C<runtime>.

=head2 failure_payload

Returns the C<home_unavailable> error hash.

=head2 render_page

Renders the home index through L<GPForum::Web::Responder>.

=head2 render_unavailable

Renders the home unavailable page as HTTP 500.

=head1 DIAGNOSTICS

JSON versus HTML negotiation stays inside L<GPForum::Web::Responder>.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<Mojo::Base>, and L<GPForum::Web::Responder>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The home reader call and error logging remain in the controller so the eval
stays on C<show>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
