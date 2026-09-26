# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::I18N::Namespace;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

sub namespace_for ( $self, $key ) {
    my $undefined;
    return $undefined if !$self->valid_key($key);

    my ($namespace) = split /[.]/msx, $key, 2;
    return $namespace;
}

sub valid_key ( $self, $key ) {
    return 0 if !defined $key || $key !~ /\A [a-z][a-z0-9_]* [.] /msx;
    return 0 if $key                  !~ /\A [a-z0-9_.-]+ \z/msx;
    return 1;
}

1;
