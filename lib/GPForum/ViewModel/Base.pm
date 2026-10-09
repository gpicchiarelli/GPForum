# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::ViewModel::Base;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;
use Scalar::Util qw(blessed);

our $VERSION = '0.001';

const my @TINTS => qw(forest steel clay);

sub column ( $self, $row, $name ) {
    return undef                   if !$row;
    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row->can('get_column');

    return undef;
}

# A column only some readers select, such as a join's title: undef from a row
# that did not load it, where get_column would die.
# A row's loaded columns as one hash: a DBIx::Class row answers get_columns
# once where a post's fifteen columns were fifteen get_column calls each
# dispatched by the row's kind; a hash is itself; a double that has neither
# is read column by column. A column not loaded is absent, as
# loaded_column would answer undef for it.
sub columns ( $self, $row, @names ) {
    return {}                    if !$row;
    return $row                  if ref $row eq 'HASH';
    return { $row->get_columns } if $row->can('get_columns');

    return { map { $_ => $self->column( $row, $_ ) } @names };
}

sub loaded_column ( $self, $row, $name ) {
    return undef         if !$row;
    return $row->{$name} if ref $row eq 'HASH';
    return undef
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
    return undef if !defined $username || !length $username;

    return q{@} . $username;
}

# The first letter of a name, for the mark that stands where a picture would:
# one grapheme, so a letter keeps its accent.
sub initial ( $self, $name ) {
    my ($first) = $self->string($name) =~ /(\X)/msx;

    return uc $self->string($first);
}

# Which of the palette's three tints the mark of a name takes. The same name
# always takes the same one, so the voices of a thread can be told apart at a
# glance without a picture.
sub tint ( $self, $name ) {
    my $sum = 0;
    for my $character ( split //msx, $self->string($name) ) {
        $sum += ord $character;
    }

    return $TINTS[ $sum % @TINTS ];
}

sub related ( $self, $row, $method ) {
    return undef if !$row || ref $row eq 'HASH' || !$row->can($method);

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
