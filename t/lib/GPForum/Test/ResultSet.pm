package GPForum::Test::ResultSet;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has schema => undef;
has name   => undef;

sub find {
    my ( $self, $query ) = @_;

    return if $self->name ne 'User';

    return _find_username( $self, $query ) || _find_email( $self, $query );
}

sub create {
    my ( $self, $row ) = @_;

    push @{ $self->schema->created_for( $self->name ) }, $row;

    return $row;
}

sub _find_username {
    my ( $self, $query ) = @_;

    return if !exists $query->{username};

    return $self->schema->existing_usernames->{ $query->{username} } ? 1 : 0;
}

sub _find_email {
    my ( $self, $query ) = @_;

    return if !exists $query->{email_normalized};

    return $self->schema->existing_emails->{ $query->{email_normalized} }
      ? 1
      : 0;
}

1;
