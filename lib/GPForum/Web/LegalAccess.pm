# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::LegalAccess;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Web::Responder;

our $VERSION = '0.001';

const my $HTTP_OK  => 200;
const my $TEMPLATE => 'legal/page';
const my $ROBOTS   => 'index,follow';
const my %SECTIONS => (
    cookies => [qw(intro session preferences operator)],
    privacy => [qw(intro data rights holds operator)],
    terms   => [qw(intro conduct moderation accounts operator)],
);

sub known_page ( $, $page ) {
    if ( !defined $page ) {
        return 0;
    }

    return exists $SECTIONS{$page} ? 1 : 0;
}

sub template {
    return $TEMPLATE;
}

sub page_payload ( $self, $page, $canonical = undef ) {
    if ( !$self->known_page($page) ) {
        my $undefined;
        return $undefined;
    }

    return {
        heading_id    => "legal-$page-heading",
        page          => $page,
        page_metadata => {
            canonical => $canonical,
            robots    => $ROBOTS,
        },
        section_keys => [ map { "legal.$page.$_" } @{ $SECTIONS{$page} } ],
        title_key    => "legal.$page",
    };
}

sub render_page ( $self, $controller, $payload ) {
    return GPForum::Web::Responder->new->payload(
        {
            controller => $controller,
            payload    => $payload,
            status     => $HTTP_OK,
            template   => $self->template,
        }
    );
}

1;

__END__

=head1 NAME

GPForum::Web::LegalAccess - Public legal-page payload and render contracts.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $payload = $access->page_payload( 'terms', $canonical );
    return $access->render_page( $controller, $payload );

=head1 DESCRIPTION

Owns the allowlisted legal page names, section catalog keys, indexable
metadata, and C<legal/page> template. It does not read PostgreSQL.
L<GPForum::Controller::Legal> still resolves the canonical URL.

=head1 SUBROUTINES/METHODS

=head2 known_page

True for C<cookies>, C<privacy>, and C<terms>.

=head2 template

Returns C<legal/page>.

=head2 page_payload

Returns the SSR/JSON hash for a known page, including heading id, title
key, section keys, and C<page_metadata>.

=head2 render_page

Renders the legal page through L<GPForum::Web::Responder>.

=head1 DIAGNOSTICS

JSON versus HTML negotiation stays inside L<GPForum::Web::Responder>.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<Mojo::Base>, and L<GPForum::Web::Responder>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Translated copy lives in L<GPForum::Service::I18N::Catalog>. Operators of a
deployed instance still replace these pages with counsel-reviewed policy
before production.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
