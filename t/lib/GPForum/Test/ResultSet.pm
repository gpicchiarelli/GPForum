package GPForum::Test::ResultSet;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;

our $VERSION = '0.001';

const my %STORAGE_ACCESSOR_FOR => (
    CommandLog    => 'command_logs',
    Credential    => 'credentials',
    IdentityToken => 'identity_tokens',
    Post          => 'posts',
    Report        => 'reports',
    Session       => 'sessions',
    User          => 'users',
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

    $self->_assert_command_unique($row);
    push @{ $self->schema->created_for( $self->name ) }, $row;
    push @{ $self->_storage_rows }, $row if $self->_has_storage_rows;

    return $row;
}

sub search {
    my ( $self, $query, $attributes ) = @_;

    if ( $self->_skip_search ) {
        return ref($self)->new(
            schema => $self->schema,
            name   => $self->name,
            rows   => [],
        );
    }

    my @rows = grep { _matches_query( $_, $query ) } @{ $self->_search_rows };

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

sub _search_rows {
    my ($self) = @_;

    if ( $self->_has_storage_rows ) {
        return $self->_storage_rows;
    }

    return [];
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

sub _skip_search {
    my ($self) = @_;

    if ( !$self->schema->can('skip_search_count') ) {
        return 0;
    }

    my $skips = $self->schema->skip_search_count;
    if ( !$skips ) {
        return 0;
    }

    $self->schema->skip_search_count( $skips - 1 );

    return 1;
}

sub _assert_command_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'CommandLog' ) {
        return;
    }
    if ( _command_key_taken( $self, $row->{idempotency_key} ) ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'command_log_idempotency_key_key');
    }

    return;
}

sub _command_key_taken {
    my ( $self, $key ) = @_;

    if ( !defined $key ) {
        return 0;
    }

    for my $existing ( @{ $self->schema->command_logs } ) {
        if ( ( $existing->{idempotency_key} || q{} ) eq $key ) {
            return 1;
        }
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
