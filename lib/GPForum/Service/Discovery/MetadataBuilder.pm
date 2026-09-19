package GPForum::Service::Discovery::MetadataBuilder;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Discovery::VisibilityPolicy;

our $VERSION = '0.001';

const my $MAX_DESCRIPTION_LENGTH => 160;

has canonical_url => undef;
has visibility_policy =>
  sub { return GPForum::Service::Discovery::VisibilityPolicy->new; };

sub thread_metadata {
    my ( $self, $thread, $body ) = @_;

    return { robots => 'noindex,nofollow' }
      if !$self->visibility_policy->is_public($thread);

    my $description =
      _excerpt( $body->{safe_text} || $body->{body_text} || q{} );

    my $canonical = $self->canonical_url->thread_url($thread);

    return {
        title       => $thread->{title},
        description => $description,
        canonical   => $canonical,
        open_graph  => {
            title       => $thread->{title},
            description => $description,
            type        => 'article',
            url         => $canonical,
        },
        robots => 'index,follow',
    };
}

sub _excerpt {
    my ($text) = @_;

    $text =~ s/<[^>]+>/ /gmsx;
    $text =~ s/\s+/ /gmsx;
    $text =~ s/\A \s+ | \s+ \z//gmsx;

    return substr $text, 0, $MAX_DESCRIPTION_LENGTH;
}

1;
