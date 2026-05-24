package GPForum::Test::IdentityStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $AT_CODE => 64;
const my $AT_SIGN => chr $AT_CODE;

has missing_profile => 0;
has duplicate       => 0;

sub create_registration {
    my ( $self, $registration ) = @_;

    return {
        ok     => 0,
        errors => {
            email    => 'email is already registered',
            username => 'username is already registered',
        },
      }
      if $self->duplicate;

    return { ok => 1, user => $registration->{user} };
}

sub public_profile {
    my ( $self, $username, $options ) = @_;

    return { ok => 0, error => 'not_found' }
      if $self->missing_profile || $username eq 'missing';

    return {
        ok      => 1,
        profile => {
            user => {
                user_id       => 'user-1',
                username      => 'giacomo_forum',
                display_name  => 'Giacomo Picchiarelli',
                status        => 'active',
                trust_level   => 2,
                created_at    => '2026-05-23T12:00:00Z',
                updated_at    => '2026-05-23T12:00:00Z',
                profile_label => $AT_SIGN . 'giacomo_forum',
            },
            trust => {
                score         => 55,
                trust_level   => 2,
                calculated_at => '2026-05-23T12:00:00Z',
                version       => 1,
            },
            threads => {
                items => [
                    {
                        thread_id        => 'thread-1',
                        category_id      => 'category-1',
                        author_user_id   => 'user-1',
                        title            => 'Welcome',
                        slug             => 'welcome',
                        visibility       => 'public',
                        moderation_state => 'visible',
                        last_activity_at => '2026-05-23T12:00:00Z',
                        created_at       => '2026-05-23T11:00:00Z',
                    },
                ],
                next_cursor => 'profile-cursor',
            },
        },
    };
}

1;
