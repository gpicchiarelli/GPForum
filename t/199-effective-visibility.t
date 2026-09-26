# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::Viewer;
use GPForum::Service::Forum::ViewerResolver;
use GPForum::Service::Forum::Visibility;

our $VERSION = '0.001';

# ADR 0102's rules, as pure functions. The readers and the SQL are tested
# against PostgreSQL in t/integration/postgres-effective-visibility.t.
my $rules = 'GPForum::Service::Forum::Visibility';

is( $rules->effective(qw(public members public)),
    'members', 'the most restrictive level wins' );
is( $rules->effective( 'public', undef ),
    'private', 'a missing level counts as private' );
is( $rules->effective(qw(public secret)), 'private', 'so does an unknown one' );

my $anonymous = GPForum::Service::Forum::Viewer->anonymous;
my $member    = GPForum::Service::Forum::Viewer->new(
    member  => 1,
    user_id => 'user-member'
);
my $suspended =
  GPForum::Service::Forum::Viewer->new( member => 0, user_id => 'user-out' );
my $granted = GPForum::Service::Forum::Viewer->new(
    category_ids => ['category-private'],
    member       => 1,
    user_id      => 'user-granted',
);
my $space_granted = GPForum::Service::Forum::Viewer->new(
    member    => 1,
    space_ids => ['space-private'],
    user_id   => 'user-space',
);
my $global = GPForum::Service::Forum::Viewer->new(
    global_read => 1,
    member      => 1,
    user_id     => 'user-admin'
);

sub row {
    my (%levels) = @_;

    return {
        category_id         => 'category-private',
        category_visibility => 'public',
        space_id            => 'space-private',
        space_visibility    => 'public',
        %levels,
    };
}

for my $case (
    [ 'a public category', row(), [ 1, 1, 1, 1, 1, 1 ] ],
    [
        'a members category',
        row( category_visibility => 'members' ),
        [ 0, 1, 0, 1, 1, 1 ]
    ],
    [
        'a private category',
        row( category_visibility => 'private' ),
        [ 0, 0, 0, 1, 1, 1 ]
    ],
    [
        'a private space',
        row( space_visibility => 'private' ),
        [ 0, 0, 0, 1, 1, 1 ]
    ],
    [
        'a category with an unknown visibility',
        row( category_visibility => 'secret' ),
        [ 0, 0, 0, 0, 0, 0 ]
    ],
  )
{
    my ( $label, $resource, $expect ) = @{$case};
    my @got = map { $rules->readable( $_, $resource ) }
      ( $anonymous, $member, $suspended, $granted, $space_granted, $global );
    is_deeply( \@got, $expect,
            "$label: anonymous, member, suspended, category grant, space grant,"
          . ' global grant' );
}

my $own_private = row(
    thread_author     => 'user-member',
    thread_visibility => 'private',
);
ok(
    $rules->readable( $member, $own_private ),
    'an author reads their own private thread'
);
ok( !$rules->readable( $suspended, $own_private ), 'another member does not' );
ok(
    !$rules->readable(
        $member, { %{$own_private}, category_visibility => 'private' }
    ),
    'and authorship never lifts a private category'
);
ok( $rules->readable( $member, row( thread_visibility => 'members' ) ),
    'a member reads a members thread' );
ok( !$rules->readable( $anonymous, row( thread_visibility => 'members' ) ),
    'an anonymous reader does not' );
ok(
    !$rules->readable(
        $member,
        row(
            post_author       => 'user-other',
            post_visibility   => 'private',
            thread_visibility => 'public'
        )
    ),
    'a private post in a public thread stays private'
);

is_deeply(
    $rules->readable_condition(
        $anonymous, { category => 'category.visibility' }
    ),
    { -and => [ { 'category.visibility' => { -in => ['public'] } } ] },
    'an anonymous condition admits public rows only'
);
is_deeply(
    $rules->readable_condition(
        $granted,
        {
            category    => 'category.visibility',
            category_id => 'category.category_id',
            space_id    => 'category.space_id',
        }
    ),
    {
        -and => [
            {
                -or => [
                    {
                        'category.visibility' =>
                          { -in => [ 'public', 'members' ] }
                    },
                    {
                        'category.visibility' => 'private',
                        -or                   => [
                            {
                                'category.category_id' =>
                                  { -in => ['category-private'] }
                            }
                        ],
                    },
                ]
            }
        ]
    },
    'a granted member also reads private rows in the granted scope'
);
is_deeply(
    $rules->readable_condition( $global, { thread => 'me.visibility' } ),
    {
        -and => [
            {
                'me.visibility' => { -in => [ 'public', 'members', 'private' ] }
            }
        ]
    },
    'a global grant reads every known level, and still no unknown one'
);

# The review of stage 1: authorship is a member's, never a suspended or
# deleted account's; the owner of a private thread reads the replies in it;
# and exactly three binding shapes grant category.read.
ok(
    !$rules->readable(
        $suspended,
        row(
            thread_author     => 'user-out',
            thread_visibility => 'private'
        )
    ),
    'a suspended author does not keep their own private thread'
);
my $reply_in_own = row(
    post_author       => 'user-other',
    post_visibility   => 'private',
    thread_author     => 'user-member',
    thread_visibility => 'private',
);
ok( $rules->readable( $member, $reply_in_own ),
    'the owner of a private thread reads a private reply in it' );
ok(
    !$rules->readable(
        $member, { %{$reply_in_own}, thread_author => 'user-third' }
    ),
    'a member who does not own the thread does not'
);

my $resolver = 'GPForum::Service::Forum::ViewerResolver';
is_deeply(
    $resolver->grant_scopes(
        [
            { resource_type => 'global' },
            { resource_type => 'space', resource_id => 'space-1' },
            {
                resource_type => 'category',
                resource_id   => 'category-1',
                space_id      => 'space-1'
            },
        ]
    ),
    {
        category_ids => ['category-1'],
        global_read  => 1,
        space_ids    => ['space-1'],
    },
    'global, space and category bindings grant their scope'
);
is_deeply(
    $resolver->grant_scopes(
        [
            {
                resource_type => 'thread',
                resource_id   => 't-1',
                space_id      => 's-1'
            },
            { resource_type => 'category', space_id => 's-1' },
            { resource_type => 'report' },
        ]
    ),
    { category_ids => [], global_read => 0, space_ids => [] },
    'and every other shape grants nothing'
);

done_testing();

1;
