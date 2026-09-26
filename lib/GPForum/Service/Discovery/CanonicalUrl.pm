# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Discovery::CanonicalUrl;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my %LEGAL_PATH => (
    cookies => '/legal/cookies',
    privacy => '/legal/privacy',
    terms   => '/legal/terms',
);

has base_url => 'https://gpforum.example';

sub space_url ( $self, $space ) {
    return $self->_absolute( '/spaces/' . _slug( $space->{slug} ) );
}

sub category_url ( $self, $category ) {
    return $self->_absolute( '/c/' . _slug( $category->{slug} ) );
}

sub thread_url ( $self, $thread ) {
    return $self->_absolute(
        '/t/' . $thread->{thread_id} . q{/} . _slug( $thread->{slug} ) );
}

sub legal_url ( $self, $page ) {
    my $path = _legal_path($page);
    if ( !$path ) {
        my $undefined;
        return $undefined;
    }

    return $self->_absolute($path);
}

sub legacy_redirect ( $self, $legacy_mapping ) {
    return {
        from   => $legacy_mapping->{canonical_url},
        to     => $self->_absolute( $legacy_mapping->{native_path} ),
        status => 301,
    };
}

sub _legal_path ($page) {
    my $undefined;

    if ( !defined $page ) {
        return $undefined;
    }
    if ( !exists $LEGAL_PATH{$page} ) {
        return $undefined;
    }

    return $LEGAL_PATH{$page};
}

sub _absolute ( $self, $path ) {
    return $self->base_url . $path;
}

sub _slug ($slug) {
    return defined $slug && length $slug ? $slug : 'untitled';
}

1;
