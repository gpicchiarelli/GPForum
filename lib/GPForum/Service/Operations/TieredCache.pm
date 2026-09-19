package GPForum::Service::Operations::TieredCache;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

our $VERSION = '0.001';

has l1    => undef;
has l2    => undef;
has stats => sub {
    return {
        hits          => 0,
        invalidations => 0,
        l2_fills      => 0,
        misses        => 0,
        writes        => 0,
    };
};

sub get {
    my ( $self, $key ) = @_;

    $self->_require_layers;
    my $local = $self->l1->get($key);
    if ( defined $local ) {
        $self->stats->{hits} += 1;
        return $local;
    }

    return $self->_fill_from_shared($key);
}

sub put {
    my ( $self, $key, $value, $options ) = @_;

    $self->_require_layers;
    $self->l1->put( $key, $value, $options );
    $self->l2->put( $key, $value, $options );
    $self->stats->{writes} += 1;
    return $value;
}

sub get_or_set {
    my ( $self, $key, $producer, $options ) = @_;

    my $cached = $self->get($key);
    if ( defined $cached ) {
        return $cached;
    }

    my $generated = $producer->();
    $self->put( $key, $generated, $options );
    return $generated;
}

sub invalidate {
    my ( $self, $key ) = @_;

    $self->_require_layers;
    my $removed = $self->l1->invalidate($key);
    $self->l2->invalidate($key);
    $self->stats->{invalidations} += $removed;
    return $removed;
}

sub invalidate_tag {
    my ( $self, $tag ) = @_;

    $self->_require_layers;
    my $removed = $self->l1->invalidate_tag($tag);
    $self->l2->invalidate_tag($tag);
    $self->stats->{invalidations} += $removed;
    return $removed;
}

sub purge_expired {
    my ($self) = @_;

    $self->_require_layers;
    my $removed = $self->l1->purge_expired;
    $self->l2->purge_expired;
    return $removed;
}

sub clear {
    my ($self) = @_;

    $self->_require_layers;
    my $removed = $self->l1->clear;
    $self->l2->clear;
    $self->stats->{invalidations} += $removed;
    return $removed;
}

sub snapshot {
    my ($self) = @_;

    $self->_require_layers;
    return {
        layer     => 'tiered',
        namespace => $self->l1->snapshot->{namespace},
        l1        => $self->l1->snapshot,
        l2        => $self->l2->snapshot,
        stats     => { %{ $self->stats } },
    };
}

sub ping {
    my ($self) = @_;

    $self->_require_layers;
    return $self->l2->ping;
}

sub _fill_from_shared {
    my ( $self, $key ) = @_;

    my $payload = $self->l2->lookup($key);
    if ( !$payload ) {
        $self->stats->{misses} += 1;
        return;
    }

    $self->l1->put( $key, $payload->{value}, { tags => $payload->{tags} || [] },
    );
    $self->stats->{l2_fills} += 1;
    $self->stats->{hits}     += 1;
    return $payload->{value};
}

sub _require_layers {
    my ($self) = @_;

    if ( !$self->l1 || !$self->l2 ) {
        croak 'tiered cache requires l1 and l2 layers';
    }

    return;
}

1;
