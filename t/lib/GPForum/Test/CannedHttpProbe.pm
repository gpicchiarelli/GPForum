# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::CannedHttpProbe;

use Mojo::Base 'GPForum::Service::Operations::HttpProbe', -signatures;
use v5.40;

our $VERSION = '0.001';

# An HttpProbe that answers what a test gives it, and keeps what it was
# asked: the URL and the headers of each request.
has answer   => sub { return { code => 200, body => q{} } };
has requests => sub { return [] };

sub get ( $self, $url, $headers = {} ) {
    push @{ $self->requests }, { url => $url, headers => { %{$headers} } };

    return { client => 'canned', %{ $self->answer } };
}

1;
