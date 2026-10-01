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

__END__

=head1 NAME

GPForum::Service::Community::MentionExtractor - Find the @username mentions in a post body.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $mentions = GPForum::Service::Community::MentionExtractor->new
      ->extract('Thanks @Alice and @bob, cc @alice');
    # [ { username => 'alice', label => '@alice' },
    #   { username => 'bob',   label => '@bob' } ]

=head1 DESCRIPTION

Pulls candidate mentions out of a body's text. A mention is C<@> followed by
a letter and then two to thirty-one letters, digits or underscores, and the
C<@> must start the text or follow a character that is neither a word
character nor a dot, so an e-mail address such as C<me@example.org> is not
taken for a mention. Usernames are lowercased and each one is returned once,
in the order it first appears. Whether the user exists is not checked here.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor; takes no attributes.

=head2 extract

Takes the body text. Returns an array reference of hash references with
C<username> (lowercased) and C<label> (C<@> plus the username), one per
distinct mention. Returns an empty array reference for an undefined or
empty body.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>.

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
