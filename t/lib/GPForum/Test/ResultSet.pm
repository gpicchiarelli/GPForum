package GPForum::Test::ResultSet;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has schema => undef;
has name   => undef;
has rows   => sub { return; };

sub find {
    my ( $self, $query ) = @_;

    return _find_user( $self, $query )    if $self->name eq 'User';
    return _find_session( $self, $query ) if $self->name eq 'Session';

    return;
}

sub create {
    my ( $self, $row ) = @_;

    push @{ $self->schema->created_for( $self->name ) }, $row;
    push @{ $self->_storage_rows }, $row if $self->_has_storage_rows;

    return $row;
}

sub search {
    my ( $self, $query, $attributes ) = @_;

    my @rows =
      $self->name eq 'Credential'
      ? grep { _matches_query( $_, $query ) } @{ $self->schema->credentials }
      : ();

    return ref($self)->new(
        schema => $self->schema,
        name   => $self->name,
        rows   => \@rows,
    );
}

sub single {
    my ($self) = @_;

    return if !$self->rows || !@{ $self->rows };

    return $self->rows->[0];
}

sub _find_user {
    my ( $self, $query ) = @_;

    return
         _find_user_row( $self, $query )
      || _find_username( $self, $query )
      || _find_email( $self, $query );
}

sub _find_user_row {
    my ( $self, $query ) = @_;

    for my $row ( @{ $self->schema->users } ) {
        return $row if _matches_query( $row, $query );
    }

    return;
}

sub _find_session {
    my ( $self, $query ) = @_;

    for my $row ( @{ $self->schema->sessions } ) {
        return $row if _matches_query( $row, $query );
    }

    return;
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

sub _matches_query {
    my ( $row, $query ) = @_;

    for my $key ( keys %{$query} ) {
        my $expected = $query->{$key};
        my $actual   = $row->{$key};
        return 0 if defined $expected  && !defined $actual;
        return 0 if !defined $expected && defined $actual;
        return 0 if defined $expected  && $actual ne $expected;
    }

    return 1;
}

sub _has_storage_rows {
    my ($self) = @_;

    return 1 if $self->name eq 'User';
    return 1 if $self->name eq 'Credential';
    return 1 if $self->name eq 'Session';

    return 0;
}

sub _storage_rows {
    my ($self) = @_;

    return $self->schema->users       if $self->name eq 'User';
    return $self->schema->credentials if $self->name eq 'Credential';
    return $self->schema->sessions    if $self->name eq 'Session';

    return [];
}

1;
