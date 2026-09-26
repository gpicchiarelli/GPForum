# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::ViewModel::Base;

use strict;
use warnings;

use Mojo::Base -base, -signatures;
use Scalar::Util qw(blessed);

our $VERSION = '0.001';

sub column ( $self, $row, $name ) {
    my $undefined;
    return $undefined              if !$row;
    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row->can('get_column');

    return $undefined;
}

# A column only some readers select, such as a join's title: undef from a row
# that did not load it, where get_column would die.
sub loaded_column ( $self, $row, $name ) {
    my $undefined;
    return $undefined    if !$row;
    return $row->{$name} if ref $row eq 'HASH';
    return $undefined
      if $row->can('has_column_loaded') && !$row->has_column_loaded($name);

    return $self->column( $row, $name );
}

sub inflated_column ( $self, $row, $name ) {
    if ( blessed $row && $row->can('get_inflated_column') ) {
        return $row->get_inflated_column($name);
    }

    return $self->column( $row, $name );
}

sub unwrap ( $self, $result, $key ) {
    return $result->{$key}
      if ref $result eq 'HASH' && exists $result->{$key};

    return $result;
}

sub profile_label ( $self, $username ) {
    my $undefined;
    return $undefined if !defined $username || !length $username;

    return q{@} . $username;
}

sub related ( $self, $row, $method ) {
    my $undefined;
    return $undefined if !$row || ref $row eq 'HASH' || !$row->can($method);

    return $row->$method;
}

sub string ( $self, $value ) {
    return q{} if !defined $value;

    return "$value";
}

sub stable_id ( $self, @parts ) {
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

sub field_error_attrs ( $self, %input ) {
    return q{} if !$input{has_error};

    return sprintf ' aria-invalid="true" aria-describedby="%s"',
      $self->string( $input{described_by} );
}

sub form_fields ( $self, %input ) {
    my $errors = $input{errors} || {};
    my $values = $input{values} || {};

    return [
        map {
            my $error_id  = $_->{id} . '-error';
            my $has_error = exists $errors->{ $_->{name} };
            +{
                %{$_},
                error       => $errors->{ $_->{name} },
                error_attrs => $self->field_error_attrs(
                    described_by => $error_id,
                    has_error    => $has_error,
                ),
                error_id => $error_id,
                value    => $values->{ $_->{value_key} || $_->{name} }
                  // $values->{ $_->{name} } // q{},
            }
        } @{ $input{specs} || [] }
    ];
}

sub form_error_fields ( $self, $fields ) {
    return [ map { { id => $_->{id}, name => $_->{name} } }
          @{ $fields || [] } ];
}

sub form_described_by ( $self, %input ) {
    my $errors           = $input{errors}     || {};
    my $summary_id       = $input{summary_id} || q{};
    my $general_key      = $input{general_key};
    my $general_error_id = $input{general_error_id} || q{};

    for my $name ( keys %{$errors} ) {
        return $summary_id if !defined $general_key || $name ne $general_key;
    }

    return defined $general_key && $errors->{$general_key}
      ? $general_error_id
      : q{};
}

1;
