# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SharedCacheClient;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

use GPForum::Test::SharedCacheError;

our $VERSION = '0.001';

# Answers as GlifiStore::Client does (GlifiStore client-semantics-v1): a GET
# of an absent key throws not_found, an ERASE of one is rejected with
# not_found, and a server that cannot be reached is unavailable. The double
# used to commit the ERASE of an absent key, which hid that SharedCache
# dropped a healthy connection on each one.
#
# mode is 'ok', 'down' (unavailable), or any other GlifiStore category, such
# as 'overloaded', which every call then fails with. calls lists each call as
# "method key". before, when set, runs at the start of every call with the
# method and key, so a test can slip another writer in between.
has before => undef;
has calls  => sub { return []; };
has mode   => sub { return 'ok'; };
has store  => sub { return {}; };

sub get {
    my ( $self, $key ) = @_;

    $self->_record( 'get', $key );
    $self->_fail_if_refusing;
    if ( !exists $self->store->{$key} ) {
        croak _error('not_found');
    }

    return $self->store->{$key};
}

sub put {
    my ( $self, $key, $value ) = @_;

    $self->_record( 'put', $key );
    my $refused = $self->_refusal;
    if ($refused) {
        return $refused;
    }

    $self->store->{$key} = $value;
    return { outcome => 'committed', error => undef };
}

sub erase {
    my ( $self, $key ) = @_;

    $self->_record( 'erase', $key );
    my $refused = $self->_refusal;
    if ($refused) {
        return $refused;
    }
    if ( !exists $self->store->{$key} ) {
        return { outcome => 'rejected', error => _error('not_found') };
    }

    delete $self->store->{$key};
    return { outcome => 'committed', error => undef };
}

sub ping {
    my ($self) = @_;

    $self->_record( 'ping', q{} );
    $self->_fail_if_refusing;
    return q{};
}

sub calls_to {
    my ( $self, $method, $key ) = @_;

    my $wanted = "$method $key";
    return scalar grep { $_ eq $wanted } @{ $self->calls };
}

sub _record {
    my ( $self, $method, $key ) = @_;

    push @{ $self->calls }, "$method $key";
    if ( $self->before ) {
        $self->before->( $method, $key );
    }

    return;
}

sub _refusal {
    my ($self) = @_;

    my $category = $self->_failure_category;
    if ( !$category ) {
        return;
    }

    return { outcome => 'rejected', error => _error($category) };
}

sub _fail_if_refusing {
    my ($self) = @_;

    my $category = $self->_failure_category;
    if ($category) {
        croak _error($category);
    }

    return;
}

sub _failure_category {
    my ($self) = @_;

    my $mode = $self->mode;
    if ( $mode eq 'ok' ) {
        return;
    }

    return $mode eq 'down' ? 'unavailable' : $mode;
}

sub _error {
    my ($category) = @_;

    return GPForum::Test::SharedCacheError->new(
        category => $category,
        message  => "$category: GlifiStore refused the request",
    );
}

1;
