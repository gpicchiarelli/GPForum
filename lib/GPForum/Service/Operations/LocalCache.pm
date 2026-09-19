package GPForum::Service::Operations::LocalCache;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $DEFAULT_NAMESPACE   => 'default';
const my $DEFAULT_TTL_SECONDS => 60;
const my $DEFAULT_MAX_ENTRIES => 512;
const my $MINIMUM_LIMIT       => 1;

has clock       => sub { return GPForum::Service::Clock->new; };
has entries     => sub { return {}; };
has max_entries => sub { return $DEFAULT_MAX_ENTRIES; };
has namespace   => sub { return $DEFAULT_NAMESPACE; };
has tag_index   => sub { return {}; };
has ttl_seconds => sub { return $DEFAULT_TTL_SECONDS; };
has stats       => sub {
    return {
        evictions     => 0,
        expired       => 0,
        hits          => 0,
        invalidations => 0,
        misses        => 0,
        writes        => 0,
    };
};

sub get {
    my ( $self, $key ) = @_;

    my ( $found, $value ) = $self->_lookup($key);

    return $found ? $value : undef;
}

sub put {
    my ( $self, $key, $value, $options ) = @_;

    $options ||= {};
    $self->_validate_key($key);
    $self->_validate_limit;
    $self->_ensure_capacity($key);
    $self->_remove_key($key);

    my $now   = $self->clock->now_epoch;
    my $ttl   = $options->{ttl_seconds} || $self->ttl_seconds;
    my $entry = {
        created_at_epoch     => $now,
        expires_at_epoch     => $now + $ttl,
        last_access_at_epoch => $now,
        tags                 => $options->{tags} || [],
        value                => $value,
    };

    $self->entries->{$key} = $entry;
    $self->_index_tags( $key, $entry->{tags} );
    $self->stats->{writes} += 1;

    return $value;
}

sub get_or_set {
    my ( $self, $key, $producer, $options ) = @_;

    my ( $found, $value ) = $self->_lookup($key);
    return $value if $found;

    my $generated = $producer->();
    $self->put( $key, $generated, $options );

    return $generated;
}

sub invalidate {
    my ( $self, $key ) = @_;

    my $removed = $self->_remove_key($key);
    $self->stats->{invalidations} += $removed;

    return $removed;
}

sub invalidate_tag {
    my ( $self, $tag ) = @_;

    return 0 if !defined $tag || !exists $self->tag_index->{$tag};

    my @keys    = keys %{ $self->tag_index->{$tag} };
    my $removed = 0;
    for my $key (@keys) {
        $removed += $self->_remove_key($key);
    }

    $self->stats->{invalidations} += $removed;

    return $removed;
}

sub purge_expired {
    my ($self) = @_;

    my $removed = 0;
    for my $key ( keys %{ $self->entries } ) {
        next if !$self->_is_expired( $self->entries->{$key} );

        $removed += $self->_remove_key($key);
    }

    $self->stats->{expired} += $removed;

    return $removed;
}

sub clear {
    my ($self) = @_;

    my $removed = scalar keys %{ $self->entries };
    $self->entries( {} );
    $self->tag_index( {} );
    $self->stats->{invalidations} += $removed;

    return $removed;
}

sub snapshot {
    my ($self) = @_;

    return {
        namespace   => $self->namespace,
        entries     => scalar keys %{ $self->entries },
        tags        => scalar keys %{ $self->tag_index },
        ttl_seconds => $self->ttl_seconds,
        max_entries => $self->max_entries,
        stats       => { %{ $self->stats } },
    };
}

sub _lookup {
    my ( $self, $key ) = @_;

    $self->_validate_key($key);

    my $entry = $self->entries->{$key};
    if ( !$entry ) {
        $self->stats->{misses} += 1;
        return ( 0, undef );
    }

    if ( $self->_is_expired($entry) ) {
        $self->_remove_key($key);
        $self->stats->{expired} += 1;
        $self->stats->{misses}  += 1;
        return ( 0, undef );
    }

    $entry->{last_access_at_epoch} = $self->clock->now_epoch;
    $self->stats->{hits} += 1;

    return ( 1, $entry->{value} );
}

sub _index_tags {
    my ( $self, $key, $tags ) = @_;

    for my $tag ( @{$tags} ) {
        next if !defined $tag || !length $tag;

        $self->tag_index->{$tag} ||= {};
        $self->tag_index->{$tag}{$key} = 1;
    }

    return;
}

sub _remove_key {
    my ( $self, $key ) = @_;

    my $entry = delete $self->entries->{$key};
    return 0 if !$entry;

    for my $tag ( @{ $entry->{tags} } ) {
        next if !exists $self->tag_index->{$tag};

        delete $self->tag_index->{$tag}{$key};
        if ( !keys %{ $self->tag_index->{$tag} } ) {
            delete $self->tag_index->{$tag};
        }
    }

    return 1;
}

sub _ensure_capacity {
    my ( $self, $key ) = @_;

    return if exists $self->entries->{$key};
    return if scalar keys %{ $self->entries } < $self->max_entries;

    $self->_evict_oldest;

    return;
}

sub _evict_oldest {
    my ($self) = @_;

    my @keys = keys %{ $self->entries };
    return if !@keys;

    my $oldest = $keys[0];
    for my $key (@keys) {
        next
          if $self->entries->{$key}{last_access_at_epoch} >=
          $self->entries->{$oldest}{last_access_at_epoch};

        $oldest = $key;
    }

    $self->_remove_key($oldest);
    $self->stats->{evictions} += 1;

    return;
}

sub _is_expired {
    my ( $self, $entry ) = @_;

    return $self->clock->now_epoch >= $entry->{expires_at_epoch} ? 1 : 0;
}

sub _validate_key {
    my ( $self, $key ) = @_;

    croak 'cache key is required'
      if !defined $key || !length $key;

    return;
}

sub _validate_limit {
    my ($self) = @_;

    croak 'cache max_entries must be positive'
      if $self->max_entries < $MINIMUM_LIMIT;

    return;
}

1;
