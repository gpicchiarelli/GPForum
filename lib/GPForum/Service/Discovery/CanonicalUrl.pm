# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Discovery::CanonicalUrl;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

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

__END__

=head1 NAME

GPForum::Service::Discovery::CanonicalUrl - Absolute canonical URLs for spaces, categories, threads and legal pages.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $urls = GPForum::Service::Discovery::CanonicalUrl->new(
        base_url => 'https://forum.example.org',
    );

    my $url = $urls->thread_url( { slug => 'hello', thread_id => $thread_id } );
    # https://forum.example.org/t/<thread_id>/hello
    my $terms = $urls->legal_url('terms');

=head1 DESCRIPTION

The one place that knows the public URL shapes, so the sitemap, the feed
and the page metadata agree on them: C</spaces/SLUG>, C</c/SLUG>,
C</t/THREAD_ID/SLUG> and C</legal/cookies>, C</legal/privacy> and
C</legal/terms>, each appended to C<base_url>. A missing or empty slug
becomes C<untitled>.

=head1 SUBROUTINES/METHODS

=head2 space_url

Takes a hash reference with C<slug>. Returns the space's absolute URL.

=head2 category_url

Takes a hash reference with C<slug>. Returns the category's absolute URL.

=head2 thread_url

Takes a hash reference with C<thread_id> and C<slug>. Returns the thread's
absolute URL.

=head2 legal_url

Takes C<cookies>, C<privacy> or C<terms>. Returns that page's absolute URL,
or undef for any other name or undef.

=head2 legacy_redirect

Takes a legacy mapping with C<canonical_url> (the old URL) and
C<native_path>. Returns C<< { from, to, status => 301 } >>, C<from> being
the old URL and C<to> the absolute URL of the native path.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

C<base_url>, default C<https://gpforum.example>, which the bootstrap sets
from the configuration's C<public_base_url>. Paths are appended to it as it
is, so it should not end in a slash.

=head1 DEPENDENCIES

None beyond L<Mojo::Base> and L<Const::Fast>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
