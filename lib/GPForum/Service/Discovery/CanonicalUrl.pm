package GPForum::Service::Discovery::CanonicalUrl;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my %LEGAL_PATH => (
    cookies => '/legal/cookies',
    privacy => '/legal/privacy',
    terms   => '/legal/terms',
);

has base_url => 'https://gpforum.example';

sub space_url {
    my ( $self, $space ) = @_;

    return $self->_absolute( '/spaces/' . _slug( $space->{slug} ) );
}

sub category_url {
    my ( $self, $category ) = @_;

    return $self->_absolute( '/c/' . _slug( $category->{slug} ) );
}

sub thread_url {
    my ( $self, $thread ) = @_;

    return $self->_absolute(
        '/t/' . $thread->{thread_id} . q{/} . _slug( $thread->{slug} ) );
}

sub legal_url {
    my ( $self, $page ) = @_;

    my $path = _legal_path($page);
    if ( !$path ) {
        return;
    }

    return $self->_absolute($path);
}

sub legacy_redirect {
    my ( $self, $legacy_mapping ) = @_;

    return {
        from   => $legacy_mapping->{canonical_url},
        to     => $self->_absolute( $legacy_mapping->{native_path} ),
        status => 301,
    };
}

sub _legal_path {
    my ($page) = @_;

    if ( !defined $page ) {
        return;
    }
    if ( !exists $LEGAL_PATH{$page} ) {
        return;
    }

    return $LEGAL_PATH{$page};
}

sub _absolute {
    my ( $self, $path ) = @_;

    return $self->base_url . $path;
}

sub _slug {
    my ($slug) = @_;

    return defined $slug && length $slug ? $slug : 'untitled';
}

1;
