# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Community::MentionExtractor;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

sub extract ( $self, $body ) {
    return [] if !defined $body || !length $body;

    my %seen;
    my @mentions;

    while ( $body =~ /(?:\A|[^\w.])[@]([[:alpha:]][[:alnum:]_]{2,31})/gmsx ) {
        my $username = lc $1;
        next if $seen{$username}++;

        push @mentions,
          {
            username => $username,
            label    => q{@} . $username,
          };
    }

    return \@mentions;
}

1;
