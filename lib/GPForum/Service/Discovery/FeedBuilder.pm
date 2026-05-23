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

sub _summary {
    my ($text) = @_;

    $text =~ s/<[^>]+>/ /gmsx;
    $text =~ s/\s+/ /gmsx;
    $text =~ s/\A \s+ | \s+ \z//gmsx;

    return substr $text, 0, $MAX_SUMMARY_LENGTH;
}

1;
