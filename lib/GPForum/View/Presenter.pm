# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::View::Presenter;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

sub action ( $self, %input ) {
    my %action = (
        href  => _string( $input{href} ),
        label => _string( $input{label} ),
    );

    for my $attribute (qw(class rel aria_label current)) {
        next
          if !defined $input{$attribute}
          || !length _string( $input{$attribute} );
        $action{$attribute} = _string( $input{$attribute} );
    }

    return \%action;
}

sub actions ( $self, @actions ) {
    my @presented = map { $self->action( %{$_} ) }
      grep { ref $_ eq 'HASH' } @actions;

    return \@presented;
}

sub next_page ( $self, %input ) {
    return [] if !defined $input{href} || !length _string( $input{href} );

    return [
        $self->action(
            href  => $input{href},
            label => $input{label},
            rel   => $input{rel} || 'next',
        )
    ];
}

sub badge ( $self, %input ) {
    return {
        label => _string( $input{label} ),
        tone  => _string( $input{tone} ) || 'neutral',
    };
}

sub _string ($value) {
    return q{} if !defined $value;
    return "$value";
}

1;
