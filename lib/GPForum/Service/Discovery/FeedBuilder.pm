# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Discovery::FeedBuilder;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Service::Discovery::VisibilityPolicy;

our $VERSION = '0.001';

const my $MAX_SUMMARY_LENGTH => 240;

__PACKAGE__->requires(qw(canonical_url));
has visibility_policy =>
  sub { return GPForum::Service::Discovery::VisibilityPolicy->new; };

sub thread_items ( $self, $threads ) {
    return [
        map {
            {
                id        => $_->{thread_id},
                title     => $_->{title},
                url       => $self->canonical_url->thread_url($_),
                updated   => $_->{last_activity_at} || $_->{created_at},
                summary   => _summary( $_->{safe_excerpt} || q{} ),
                full_body => undef,
            }
        } grep { $self->visibility_policy->is_public($_) } @{$threads}
    ];
}

sub render_atom ( $self, $feed ) {
    my @entries = map { _atom_entry($_) } @{ $feed->{items} || [] };

    return join "\n",
      '<?xml version="1.0" encoding="UTF-8"?>',
      '<feed xmlns="http://www.w3.org/2005/Atom">',
      '  <id>' . _xml_escape( $feed->{id} ) . '</id>',
      '  <title>' . _xml_escape( $feed->{title} ) . '</title>',
      '  <link href="' . _xml_escape( $feed->{url} ) . '" rel="self" />',
      '  <updated>' . _xml_escape( $feed->{updated} ) . '</updated>',
      @entries,
      '</feed>',
      q{};
}

sub _summary ($text) {
    $text =~ s/<[^>]+>/ /gmsx;
    $text =~ s/\s+/ /gmsx;
    $text =~ s/\A \s+ | \s+ \z//gmsx;

    return substr $text, 0, $MAX_SUMMARY_LENGTH;
}

sub _atom_entry ($item) {
    return join "\n",
      '  <entry>',
      '    <id>' . _xml_escape( $item->{url} ) . '</id>',
      '    <title>' . _xml_escape( $item->{title} ) . '</title>',
      '    <link href="' . _xml_escape( $item->{url} ) . '" />',
      '    <updated>' . _xml_escape( $item->{updated} ) . '</updated>',
      '    <summary>' . _xml_escape( $item->{summary} ) . '</summary>',
      '  </entry>';
}

sub _xml_escape ($value) {
    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/&/&amp;/gmsx;
    $value =~ s/</&lt;/gmsx;
    $value =~ s/>/&gt;/gmsx;
    $value =~ s/"/&quot;/gmsx;

    return $value;
}

1;

__END__

=head1 NAME

GPForum::Service::Discovery::FeedBuilder - The public Atom feed of threads.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $builder = GPForum::Service::Discovery::FeedBuilder->new(
        canonical_url => GPForum::Service::Discovery::CanonicalUrl->new(
            base_url => 'https://forum.example',
        ),
    );

    my $items = $builder->thread_items($threads);
    my $atom  = $builder->render_atom(
        {
            id      => 'https://forum.example/feed.atom',
            title   => 'Public discussions',
            url     => 'https://forum.example/feed.atom',
            updated => '2026-05-23T12:00:00Z',
            items   => $items,
        }
    );

=head1 DESCRIPTION

Turns thread rows into feed items and feed items into an Atom document. Only
threads that L<GPForum::Service::Discovery::VisibilityPolicy> calls public
become items, and an item carries a summary built from the thread's
C<safe_excerpt>, never the full body: tags are replaced by spaces, whitespace
is collapsed, and the text is cut to 240 characters. Every value written into
the XML is escaped.

=head1 SUBROUTINES/METHODS

=head2 thread_items

Takes an array reference of thread hashes. Returns an array reference of
items, one per public thread, each with C<id> (the thread id), C<title>,
C<url> (from C<< canonical_url->thread_url >>), C<updated>
(C<last_activity_at>, or C<created_at>), C<summary> and C<full_body>, which is
always undef.

=head2 render_atom

Takes a hash reference with C<id>, C<title>, C<url>, C<updated> and
C<items>. Returns the Atom XML as a string: the feed header with a C<self>
link, then one C<entry> per item using its C<url> as id and link, its
C<title>, C<updated> and C<summary>.

=head1 DIAGNOSTICS

None. Undefined values render as empty elements.

=head1 CONFIGURATION AND ENVIRONMENT

None here: C<canonical_url> carries the public base URL.

=head1 DEPENDENCIES

L<GPForum::Service::Discovery::VisibilityPolicy>,
L<GPForum::Service::Discovery::CanonicalUrl>.

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
