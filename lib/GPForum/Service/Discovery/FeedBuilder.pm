package GPForum::Service::Discovery::FeedBuilder;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Discovery::VisibilityPolicy;

our $VERSION = '0.001';

const my $MAX_SUMMARY_LENGTH => 240;

has canonical_url => undef;
has visibility_policy =>
  sub { return GPForum::Service::Discovery::VisibilityPolicy->new; };

sub thread_items {
    my ( $self, $threads ) = @_;

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

sub render_atom {
    my ( $self, $feed ) = @_;

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

sub _summary {
    my ($text) = @_;

    $text =~ s/<[^>]+>/ /gmsx;
    $text =~ s/\s+/ /gmsx;
    $text =~ s/\A \s+ | \s+ \z//gmsx;

    return substr $text, 0, $MAX_SUMMARY_LENGTH;
}

sub _atom_entry {
    my ($item) = @_;

    return join "\n",
      '  <entry>',
      '    <id>' . _xml_escape( $item->{url} ) . '</id>',
      '    <title>' . _xml_escape( $item->{title} ) . '</title>',
      '    <link href="' . _xml_escape( $item->{url} ) . '" />',
      '    <updated>' . _xml_escape( $item->{updated} ) . '</updated>',
      '    <summary>' . _xml_escape( $item->{summary} ) . '</summary>',
      '  </entry>';
}

sub _xml_escape {
    my ($value) = @_;

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
