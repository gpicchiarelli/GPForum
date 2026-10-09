# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::RenderPolicy;

use GPForum::X::Argument;
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::Util qw(xml_escape);

our $VERSION = '0.001';

sub trusted_html ( $self, %input ) {
    my $context = $input{context} || q{};
    if ( !$self->trusted_context($context) ) {
        GPForum::X::Argument->throw(
            message => "untrusted html context: $context" );
    }

    return defined $input{html} ? "$input{html}" : q{};
}

sub attribute ( $self, %input ) {
    my $name = $input{name} || q{};
    if ( $name !~ /\A [[:alpha:]_:] [[:alnum:]_.:-]* \z/msxa ) {
        GPForum::X::Argument->throw(
            message => "unsafe attribute name: $name" );
    }

    return q{ } . $name
      if $input{boolean};

    return q{} if !defined $input{value};

    return sprintf q{ %s="%s"}, $name, xml_escape( $input{value} );
}

sub trusted_context ( $self, $context ) {
    my %allowed = map { $_ => 1 } qw(
      forum.post.body
      search.snippet
    );

    return $allowed{$context} ? 1 : 0;
}

1;

__END__

=head1 NAME

GPForum::Web::RenderPolicy - The only ways a template may emit raw HTML or build an attribute.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $policy = GPForum::Web::RenderPolicy->new;

    my $html = $policy->trusted_html(
        context => 'search.snippet',
        html    => $result->{snippet_html},
    );
    my $attr = $policy->attribute( name => 'data-id', value => $id );
    my $flag = $policy->attribute( name => 'hidden', boolean => 1 );

=head1 DESCRIPTION

Templates escape by default. Markup that must reach the page unescaped goes
through C<trusted_html>, which accepts it only from a named context on a
short allowlist: C<forum.post.body> (a post body on the thread page) and
C<search.snippet> (a search result excerpt). Anything else throws, so
a new raw-HTML site has to be added here on purpose. C<attribute> builds an
HTML attribute with a checked name and an escaped value. The C<ui_trusted_html>
and C<ui_attr> template helpers call these methods.

=head1 SUBROUTINES/METHODS

=head2 trusted_html

Takes a hash with C<context> and C<html>. Returns C<html> stringified, or an
empty string when it is undefined. Throws when C<context> is not an allowed
context.

=head2 attribute

Takes a hash with C<name>, and C<value> or C<boolean>. Returns the attribute
text with a leading space: C< name> when C<boolean> is true, C< name="value">
with the value XML-escaped otherwise, and an empty string when C<value> is
undefined. Throws when C<name> is not a safe attribute name (a letter,
underscore or colon followed by letters, digits, C<_>, C<.>, C<:> or C<->).

=head2 trusted_context

Takes a context name. Returns 1 when raw HTML is allowed from it
(C<forum.post.body> or C<search.snippet>) and 0 otherwise.

=head1 DIAGNOSTICS

A L<GPForum::X::Argument>: C<untrusted html context: CONTEXT> from
C<trusted_html>, and C<unsafe attribute name: NAME> from C<attribute>.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::X::Argument>, L<Mojo::Base>, L<Mojo::Util>.

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
