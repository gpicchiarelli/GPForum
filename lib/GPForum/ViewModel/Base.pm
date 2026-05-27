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

sub field_error_attrs {
    my ( $self, %input ) = @_;

    return q{} if !$input{has_error};

    return sprintf ' aria-invalid="true" aria-describedby="%s"',
      $self->string( $input{described_by} );
}

1;
