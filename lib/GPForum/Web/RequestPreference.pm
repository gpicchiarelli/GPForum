package GPForum::Web::RequestPreference;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub wants_json {
    my ( $self, $controller ) = @_;

    my $format = $controller->param('format') || q{};
    return 1 if $format eq 'json';

    my $accept = $controller->req->headers->accept || q{};
    return $accept =~ m{application/json}msx ? 1 : 0;
}

1;
