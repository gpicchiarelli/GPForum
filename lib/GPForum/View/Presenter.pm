package GPForum::View::Presenter;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub action {
    my ( $self, %input ) = @_;

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

sub actions {
    my ( $self, @actions ) = @_;

    my @presented = map { $self->action( %{$_} ) }
      grep { ref $_ eq 'HASH' } @actions;

    return \@presented;
}

sub next_page {
    my ( $self, %input ) = @_;

    return [] if !defined $input{href} || !length _string( $input{href} );

    return [
        $self->action(
            href  => $input{href},
            label => $input{label},
            rel   => $input{rel} || 'next',
        )
    ];
}

sub badge {
    my ( $self, %input ) = @_;

    return {
        label => _string( $input{label} ),
        tone  => _string( $input{tone} ) || 'neutral',
    };
}

sub _string {
    my ($value) = @_;

    return q{} if !defined $value;
    return "$value";
}

1;
