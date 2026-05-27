package GPForum::ViewModel::Base;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub column {
    my ( $self, $row, $name ) = @_;

    my $undefined;
    return $undefined              if !$row;
    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row->can('get_column');

    return $undefined;
}

sub unwrap {
    my ( $self, $result, $key ) = @_;

    return $result->{$key}
      if ref $result eq 'HASH' && exists $result->{$key};

    return $result;
}

sub profile_label {
    my ( $self, $username ) = @_;

    my $undefined;
    return $undefined if !defined $username || !length $username;

    return q{@} . $username;
}

sub related {
    my ( $self, $row, $method ) = @_;

    return if !$row || ref $row eq 'HASH' || !$row->can($method);

    return $row->$method;
}

sub string {
    my ( $self, $value ) = @_;

    return q{} if !defined $value;

    return "$value";
}

sub stable_id {
    my ( $self, @parts ) = @_;

    my @tokens;
    for my $part (@parts) {
        my $token = $self->string($part);
        $token =~ s/[^A-Za-z0-9_.:-]+/-/gmsx;
        $token =~ s/\A-+//msx;
        $token =~ s/-+\z//msx;
        push @tokens, $token if length $token;
    }

    return join q{-}, @tokens;
}

sub field_error_attrs {
    my ( $self, %input ) = @_;

    return q{} if !$input{has_error};

    return sprintf ' aria-invalid="true" aria-describedby="%s"',
      $self->string( $input{described_by} );
}

1;
