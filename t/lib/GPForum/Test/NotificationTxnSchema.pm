package GPForum::Test::NotificationTxnSchema;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base 'GPForum::Test::NotificationSchema';

our $VERSION = '0.001';

has commit_fails   => 0;
has in_transaction => 0;
has transactions   => 0;

sub txn_do {
    my ( $self, $code ) = @_;

    $self->transactions( $self->transactions + 1 );
    $self->in_transaction(1);
    my $result = $code->();
    $self->in_transaction(0);
    if ( $self->commit_fails ) {
        croak 'commit failed';
    }

    return $result;
}

1;
