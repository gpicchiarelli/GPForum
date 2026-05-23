package GPForum::Worker::IdempotentJobRunner;

use strict;
use warnings;

use Mojo::Base -base;
use Try::Tiny;

our $VERSION = '0.001';

has store => undef;

sub run {
    my ( $self, $idempotency_key, $code ) = @_;

    return { ok => 1, skipped => 1 }
      if $self->store->is_done($idempotency_key);

    $self->store->begin($idempotency_key);

    my $result = try {
        my $value = $code->();
        $self->store->mark_done( $idempotency_key, $value );
        return { ok => 1, skipped => 0, result => $value };
    }
    catch {
        $self->store->mark_failed( $idempotency_key, "$_" );
        return { ok => 0, skipped => 0, error => "$_" };
    };

    return $result;
}

1;
