package GPForum::Service::Community::FeedProjector;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $DEFAULT_RANK               => 0;
const my $DEFAULT_VISIBILITY_VERSION => 1;
const my $DEFAULT_PERMISSION_VERSION => 1;

has schema => undef;

sub project_item {
    my ( $self, $input ) = @_;

    my @users = _unique_users( $input->{user_ids} || [] );
    my @items;

    for my $user_id (@users) {
        my $item = _item_for_user( $user_id, $input );
        $self->schema->resultset('UserFeedItem')->update_or_create($item);
        push @items, $item;
    }

    return { ok => 1, projected => scalar @items, items => \@items };
}

sub remove_item {
    my ( $self, $input ) = @_;

    return { ok => 1, removed => 0 } if !_item_key($input);

    my $deleted = $self->schema->resultset('UserFeedItem')->search(
        {
            item_id   => $input->{item_id},
            item_type => $input->{item_type},
        }
    )->delete;

    return { ok => 1, removed => $deleted || 0 };
}

sub _item_key {
    my ($input) = @_;

    return defined $input->{item_type}
      && defined $input->{item_id} ? 1 : 0;
}

sub _item_for_user {
    my ( $user_id, $input ) = @_;

    return {
        user_id            => $user_id,
        item_type          => $input->{item_type},
        item_id            => $input->{item_id},
        created_at         => $input->{created_at},
        rank_score         => $input->{rank_score} || $DEFAULT_RANK,
        visibility_version => $input->{visibility_version}
          || $DEFAULT_VISIBILITY_VERSION,
        permission_version => $input->{permission_version}
          || $DEFAULT_PERMISSION_VERSION,
    };
}

sub _unique_users {
    my ($users) = @_;

    my %seen;

    return grep { defined && !$seen{$_}++ } @{$users};
}

1;
