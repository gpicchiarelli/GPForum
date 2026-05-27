package GPForum::Test::Schema;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::ResultSet;

our $VERSION = '0.001';

has created            => sub { return {}; };
has transactions       => 0;
has existing_usernames => sub { return {}; };
has existing_emails    => sub { return {}; };
has users              => sub { return []; };
has credentials        => sub { return []; };
has reports            => sub { return []; };
has sessions           => sub { return []; };

sub resultset {
    my ( $self, $name ) = @_;

    return GPForum::Test::ResultSet->new( schema => $self, name => $name );
}

sub txn_do {
    my ( $self, $code ) = @_;

    $self->transactions( $self->transactions + 1 );

    return $code->();
}

sub created_for {
    my ( $self, $name ) = @_;

    $self->created->{$name} ||= [];

    return $self->created->{$name};
}

sub transaction_count {
    my ($self) = @_;

    return $self->transactions;
}

1;
