# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::RenderPolicy;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base, -signatures;
use Mojo::Util qw(xml_escape);

our $VERSION = '0.001';

sub trusted_html ( $self, %input ) {
    my $context = $input{context} || q{};
    croak "untrusted html context: $context"
      if !$self->trusted_context($context);

    return defined $input{html} ? "$input{html}" : q{};
}

sub attribute ( $self, %input ) {
    my $name = $input{name} || q{};
    croak "unsafe attribute name: $name"
      if $name !~ /\A [a-zA-Z_:] [a-zA-Z0-9_.:-]* \z/msx;

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
