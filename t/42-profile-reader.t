# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use MIME::Base64 qw(encode_base64url);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Identity::ProfileReader;
use GPForum::Test::ForumReadResultSet;
use GPForum::Test::ForumReadRow;
use GPForum::Test::ForumReadSchema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 29;
const my $PROFILE_LIMIT  => 1;
const my $FETCH_ROWS     => $PROFILE_LIMIT + 1;
const my $TRUST_SCORE    => 55;
const my $AT_CODE        => 64;
const my $AT_SIGN        => chr $AT_CODE;

plan tests => $EXPECTED_TESTS;

my $users = GPForum::Test::ForumReadResultSet->new(
    rows => [
        _row(
            {
                id           => 'user-1',
                username     => 'giacomo',
                display_name => 'Giacomo Picchiarelli',
                status       => 'active',
                trust_level  => 1,
                created_at   => '2026-05-23T12:00:00Z',
                updated_at   => '2026-05-23T12:00:00Z',
                deleted_at   => undef,
            }
        ),
    ],
);
my $trust = GPForum::Test::ForumReadResultSet->new(
    rows => [
        _row(
            {
                user_id       => 'user-1',
                score         => $TRUST_SCORE,
                trust_level   => 2,
                calculated_at => '2026-05-23T12:00:00Z',
                version       => 3,
            }
        ),
    ],
);
my $threads = GPForum::Test::ForumReadResultSet->new(
    filter_rows => 1,
    rows        => [
        _row(
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
            }
        ),
        _row(
            {
                thread_id        => 'thread-2',
                category_id      => 'category-1',
                author_user_id   => 'user-1',
                title            => 'Second',
                slug             => 'second',
                visibility       => 'public',
                moderation_state => 'visible',
                last_activity_at => '2026-05-23T11:00:00Z',
                created_at       => '2026-05-23T10:00:00Z',
            }
        ),
    ],
);
my $posts = GPForum::Test::ForumReadResultSet->new(
    filter_rows => 1,
    rows        => [
        _row(
            {
                post_id                 => 'post-2',
                thread_id               => 'thread-1',
                author_user_id          => 'user-1',
                position                => 2,
                visibility              => 'public',
                moderation_state        => 'visible',
                created_at              => '2026-05-23T12:30:00Z',
                thread_visibility       => 'public',
                thread_moderation_state => 'visible',
                thread_deleted_at       => undef,
                thread_title            => 'Welcome',
                thread_slug             => 'welcome',
                body                    => 'Public reply',
            }
        ),
        _row(
            {
                post_id                 => 'post-hidden',
                thread_id               => 'thread-1',
                author_user_id          => 'user-1',
                position                => 3,
                visibility              => 'public',
                moderation_state        => 'hidden',
                created_at              => '2026-05-23T12:20:00Z',
                thread_visibility       => 'public',
                thread_moderation_state => 'visible',
                thread_title            => 'Hidden reply',
                body                    => 'hidden content must not leak',
            }
        ),
        _row(
            {
                post_id                 => 'post-private',
                thread_id               => 'thread-1',
                author_user_id          => 'user-1',
                position                => 4,
                visibility              => 'private',
                moderation_state        => 'visible',
                created_at              => '2026-05-23T12:10:00Z',
                thread_visibility       => 'public',
                thread_moderation_state => 'visible',
                thread_title            => 'Private reply',
                body                    => 'private reply must not leak',
            }
        ),
        _row(
            {
                post_id                 => 'post-private-thread',
                thread_id               => 'thread-private',
                author_user_id          => 'user-1',
                position                => 2,
                visibility              => 'public',
                moderation_state        => 'visible',
                created_at              => '2026-05-23T12:05:00Z',
                thread_visibility       => 'private',
                thread_moderation_state => 'visible',
                thread_title            => 'Private thread',
                body                    => 'private thread reply must not leak',
            }
        ),
        _row(
            {
                post_id                 => 'post-opening',
                thread_id               => 'thread-1',
                author_user_id          => 'user-1',
                position                => 1,
                visibility              => 'public',
                moderation_state        => 'visible',
                created_at              => '2026-05-23T11:00:00Z',
                thread_visibility       => 'public',
                thread_moderation_state => 'visible',
                thread_title            => 'Welcome',
                body                    => 'Opening post',
            }
        ),
    ],
);
my $schema = GPForum::Test::ForumReadSchema->new(
    resultsets => {
        User               => $users,
        TrustScoreSnapshot => $trust,
        Thread             => $threads,
        Post               => $posts,
    },
);
my $reader =
  GPForum::Service::Identity::ProfileReader->new( schema => $schema );
my $profile =
  $reader->public_profile( ' Giacomo ', { limit => $PROFILE_LIMIT } );

ok( $profile->{ok}, 'profile reader returns public profile' );
is(
    $profile->{profile}{user}{display_name},
    'Giacomo Picchiarelli',
    'profile exposes display name'
);
is(
    $profile->{profile}{user}{profile_label},
    $AT_SIGN . 'giacomo',
    'profile exposes public username label'
);
ok( !exists $profile->{profile}{user}{email_normalized},
    'profile does not expose email' );
is( $profile->{profile}{trust}{score},
    $TRUST_SCORE, 'profile exposes trust score' );
is(
    $profile->{profile}{trust}{badge},
    'Trusted contributor',
    'profile exposes trust badge'
);
is( $profile->{profile}{counts}{public_threads},
    2, 'profile counts public threads' );
is( $profile->{profile}{counts}{public_replies},
    1, 'profile counts public replies' );
is( $profile->{profile}{counts}{total_public},
    3, 'profile counts total public contributions' );
is( scalar @{ $profile->{profile}{threads}{items} },
    1, 'profile threads are keyset-windowed' );
is( $profile->{profile}{threads}{items}[0]{title},
    'Welcome', 'profile exposes public thread title' );
is( scalar @{ $profile->{profile}{replies}{items} },
    1, 'profile replies exclude hidden, private, and opening posts' );
is( $profile->{profile}{replies}{items}[0]{thread_title},
    'Welcome', 'profile exposes public reply thread title' );
is( $profile->{profile}{replies}{items}[0]{post_id},
    'post-2', 'profile keeps hidden and private reply ids out' );
is( $profile->{profile}{replies}{items}[0]{body},
    'Public reply', 'profile exposes only public reply body' );
ok(
    $profile->{profile}{threads}{next_cursor},
    'profile exposes next cursor for public threads'
);
is( $users->last_query->{username},
    'giacomo', 'profile lookup normalizes username' );
is( $threads->last_query->{'me.author_user_id'},
    'user-1', 'profile thread query scopes by author' );
is_deeply(
    [ @{ $threads->last_query }{qw(category.visibility space.visibility)} ],
    [ 'public', 'public' ],
    'and lists only threads in public categories of public spaces (ADR 0102)'
);
is( $threads->last_attrs->{rows},
    $FETCH_ROWS, 'profile thread query fetches one extra row' );
ok(
    !exists $threads->last_attrs->{offset},
    'profile thread query does not use offset'
);
is( $posts->last_query->{'me.author_user_id'},
    'user-1', 'profile reply query scopes by author' );
is( $posts->last_query->{'thread.visibility'},
    'public', 'profile reply query scopes by public thread visibility' );
is( $posts->last_attrs->{rows},
    $FETCH_ROWS, 'profile reply query fetches one extra row' );
ok(
    !exists $posts->last_attrs->{offset},
    'profile reply query does not use offset'
);

my $cursor =
  encode_base64url('2026-05-23T12:00:00Z|018f1000-0000-7000-8000-000000000001');
$reader->public_profile( 'giacomo',
    { limit => $PROFILE_LIMIT, after => $cursor } );
ok(
    exists $threads->last_query->{-or},
    'profile thread query applies keyset cursor'
);

my $missing = $reader->public_profile( 'missing', { limit => $PROFILE_LIMIT } );
ok( !$missing->{ok}, 'missing profile is not public' );

my $deleted =
  GPForum::Service::Identity::ProfileReader->new( schema =>
      _schema_for_user( { username => 'deleted', deleted_at => 'now' } ) )
  ->public_profile( 'deleted', { limit => $PROFILE_LIMIT } );
ok( !$deleted->{ok}, 'deleted profile is not public' );

my $suspended =
  GPForum::Service::Identity::ProfileReader->new( schema =>
      _schema_for_user( { username => 'suspended', status => 'suspended' } ) )
  ->public_profile( 'suspended', { limit => $PROFILE_LIMIT } );
ok( !$suspended->{ok}, 'suspended profile is not public' );

sub _schema_for_user {
    my ($overrides) = @_;

    my $user = {
        id           => 'user-x',
        username     => $overrides->{username},
        display_name => 'Hidden User',
        status       => $overrides->{status} || 'active',
        trust_level  => 0,
        created_at   => '2026-05-23T12:00:00Z',
        updated_at   => '2026-05-23T12:00:00Z',
        deleted_at   => $overrides->{deleted_at},
    };

    return GPForum::Test::ForumReadSchema->new(
        resultsets => {
            User => GPForum::Test::ForumReadResultSet->new(
                rows => [ _row($user) ],
            ),
            TrustScoreSnapshot =>
              GPForum::Test::ForumReadResultSet->new( rows => [] ),
            Thread => GPForum::Test::ForumReadResultSet->new( rows => [] ),
            Post   => GPForum::Test::ForumReadResultSet->new( rows => [] ),
        },
    );
}

sub _row {
    my ($data) = @_;

    return GPForum::Test::ForumReadRow->new( data => $data );
}

1;
