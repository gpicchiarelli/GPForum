package GPForum::Service::Community::MentionExtractor;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub extract {
    my ( $self, $body ) = @_;

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
