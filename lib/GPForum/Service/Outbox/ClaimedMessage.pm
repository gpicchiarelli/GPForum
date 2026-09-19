package GPForum::Service::Outbox::ClaimedMessage;

use strict;
use warnings;

use JSON::MaybeXS qw(decode_json);
use Mojo::Base -base;

our $VERSION = '0.001';

has row            => sub { return {}; };
has update_handler => undef;

sub get_column {
    my ( $self, $column ) = @_;

    return $self->_payload if $column eq 'payload';

    return $self->row->{$column};
}

sub update {
    my ( $self, $changes ) = @_;

    if ( $self->update_handler ) {
        $self->update_handler->( $self, $changes );
    }

    $self->apply_columns($changes);

    return $self;
}

sub apply_columns {
    my ( $self, $changes ) = @_;

    for my $column ( keys %{$changes} ) {
        $self->row->{$column} = $changes->{$column};
    }

    return $self;
}

sub is_direct_outbox_message {
    return 1;
}

sub _payload {
    my ($self) = @_;

    my $payload = $self->row->{payload};
    return {}       if !defined $payload || $payload eq q{};
    return $payload if ref $payload;

    my $decoded = eval { return decode_json($payload); };
    return $decoded if ref $decoded eq 'HASH';

    return {};
}

1;
