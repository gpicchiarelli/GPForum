# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::I18N::Namespace;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

sub namespace_for ( $self, $key ) {
    return undef if !$self->valid_key($key);

    my ($namespace) = split /[.]/msx, $key, 2;
    return $namespace;
}

sub valid_key ( $self, $key ) {
    return 0 if !defined $key;
    return 0 if $key !~ /\A [[:lower:]] [[:lower:][:digit:]_]* [.] /msxa;
    return 0 if $key !~ /\A [[:lower:][:digit:]_.-]+ \z/msxa;
    return 1;
}

1;
