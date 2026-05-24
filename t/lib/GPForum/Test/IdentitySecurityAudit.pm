package GPForum::Test::IdentitySecurityAudit;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has records => sub { return []; };

sub record_login_request {
    my ( $self, $input ) = @_;

    push @{ $self->records },
      {
        input  => { %{$input} },
        method => 'record_login_request',
      };

    return { ok => 1 };
}

sub record_logout_request {
    my ( $self, $input ) = @_;

    push @{ $self->records },
      {
        input  => { %{$input} },
        method => 'record_logout_request',
      };

    return { ok => 1 };
}

1;
