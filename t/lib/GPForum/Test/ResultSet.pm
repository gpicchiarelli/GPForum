package GPForum::Test::ResultSet;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my %STORAGE_ACCESSOR_FOR => (
    Credential => 'credentials',
    Post       => 'posts',
    Report     => 'reports',
    Session    => 'sessions',
    User       => 'users',
);

has schema => undef;
has name   => undef;
has rows   => sub { return; };

sub find {
    my ( $self, $query ) = @_;

    return _find_user( $self, $query )    if $self->name eq 'User';
    return _find_session( $self, $query ) if $self->name eq 'Session';

    return;
}

sub count {
    my ($self) = @_;

    return 0 if !$self->rows;

    return scalar @{ $self->rows };
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
      $self->name eq 'Credential' ? grep { _matches_query( $_, $query ) }
      @{ $self->schema->credentials }
      : $self->name eq 'User' ? grep { _matches_query( $_, $query ) }
      @{ $self->schema->users }
      : $self->name eq 'Post' ? grep { _matches_query( $_, $query ) }
      @{ $self->schema->posts }
      : $self->name eq 'Report' ? grep { _matches_query( $_, $query ) }
      @{ $self->schema->reports }
      : ();

    return ref($self)->new(
        schema => $self->schema,
        name   => $self->name,
        rows   => \@rows,
    );
}

sub all {
    my ($self) = @_;

    return if !$self->rows;

    return @{ $self->rows };
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
        if ( ref $expected eq 'HASH' && exists $expected->{-in} ) {
            return 0 if !_in_list( $actual, $expected->{-in} );
            next;
        }
        return 0 if defined $expected  && !defined $actual;
        return 0 if !defined $expected && defined $actual;
        return 0 if defined $expected  && $actual ne $expected;
    }

    return 1;
}

sub _in_list {
    my ( $actual, $values ) = @_;

    return 0 if !defined $actual;

    for my $value ( @{$values} ) {
        return 1 if defined $value && $actual eq $value;
    }

    return 0;
}

sub _has_storage_rows {
    my ($self) = @_;

    return exists $STORAGE_ACCESSOR_FOR{ $self->name } ? 1 : 0;
}

sub _storage_rows {
    my ($self) = @_;

    my $accessor = $STORAGE_ACCESSOR_FOR{ $self->name };
    return $self->schema->$accessor if $accessor;

    return [];
}

1;
