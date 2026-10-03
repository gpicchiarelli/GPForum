# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use JSON::MaybeXS;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::Id;
use GPForum::Service::Admin::CategoryStore;
use GPForum::Test::FixedClock;
use GPForum::Test::PgDatabase;
use GPForum::Test::RacedSchema;
use GPForum::Test::ScriptedId;
use GPForum::Worker::Handler::CacheInvalidation;

our $VERSION = '0.001';
our $TODO;

const my $NOW         => '2026-05-23T12:00:00Z';
const my $LATER       => '2026-05-23T13:00:00Z';
const my $LIST_LIMIT  => 10;
const my $TOP         => -1;
const my $PUBLIC_HTML => 'forum:public-html';
const my $CREATED     => 'category.created';
const my $UPDATED     => 'category.updated';
const my @TABLES => qw(spaces categories event_log outbox_messages
  audit_log);

const my $SPACE_SQL => join q{ },
  'INSERT INTO spaces (space_id, slug, title) VALUES (?, ?, ?)';
const my $CATEGORY_SQL => join q{ },
  'INSERT INTO categories (category_id, space_id, slug, title)',
  'VALUES (?, ?, ?, ?)';
const my $SPACE_BY_SLUG_SQL => 'SELECT space_id FROM spaces WHERE slug = ?';
const my $EVENT_TYPES_SQL => join q{ },
  'SELECT event_type FROM event_log WHERE aggregate_id = ?',
  'ORDER BY aggregate_version';
const my $AUDITS_SQL => join q{ },
  'SELECT action, target_type FROM audit_log WHERE target_id = ?',
  'ORDER BY action';
const my $OUTBOX_PAYLOAD_SQL => join q{ },
  'SELECT payload FROM outbox_messages',
  q{WHERE payload->>'aggregate_id' = ? AND payload->>'event_type' = ?};
const my $CATEGORY_ROW_SQL => join q{ },
  'SELECT title, slug, visibility, version,',
  q{to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')},
  'FROM categories WHERE category_id = ?';
const my $DELETE_SQL =>
  'UPDATE categories SET deleted_at = now() WHERE category_id = ?';

# The defect this test found in code outside its reach, pinned where it shows
# (quality program 5.1).
const my $MALFORMED_TODO =>
'CategoryStore hands an id that is not a uuid to PostgreSQL, which refuses it';

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the admin category test';
}

# The admin category store on PostgreSQL: a category's first write with its
# event, outbox message and audit entry, the default space a fresh install
# gets, edits and their visibility, the listing's order, and every race the
# store recovers from. These ran on a fake ORM (t/145, removed when they
# moved here) whose searches matched rows in Perl and whose unique keys were
# its own; here the unique violation, the savepoint that recovers from it and
# the row read back are PostgreSQL's. Only the look that misses is scripted
# (GPForum::Test::RacedSchema), and the id a store mints when a collision is
# the point (GPForum::Test::ScriptedId).
my $install = _context( GPForum::Test::PgDatabase->fresh );
my $first   = _fresh_install($install);
_repeat_and_slug_race( $install, $first );
_edit( $install, $first );
_unchanged_edit( $install, $first );
_default_space_reused( $install, $first );
_listing($install);
_missing_rows($install);

# The id collisions need a database the default space is not in yet.
_space_and_category_collisions( _context( GPForum::Test::PgDatabase->fresh ) );

done_testing();

sub _context {
    my ($database) = @_;

    return {
        actor_id => GPForum::Infrastructure::Id->new->uuid,
        database => $database,
        dbh      => $database->dbh,
        schema   => $database->schema,
    };
}

# A fresh install has no space: the first category provisions the public
# "general" one, and its write is one event, one outbox message and one audit
# entry, all named for the category.
sub _fresh_install {
    my ($ctx) = @_;

    is( _tally($ctx)->{spaces}, 0, 'a fresh install has no space' );
    my $created = _create(
        $ctx,
        {
            description => 'Welcome board',
            title       => 'General Discussion',
        }
    );
    is( $created->{title}, 'General Discussion', 'create stores the title' );
    is( $created->{slug},  'general-discussion', 'create derives a slug' );
    is( $created->{visibility}, 'public', 'create defaults public visibility' );
    is(
        $created->{space_id},
        _space_id( $ctx, 'general' ),
        'create provisions the default general space on a fresh install'
    );
    is_deeply(
        _tally($ctx),
        {
            audit_log       => 1,
            categories      => 1,
            event_log       => 1,
            outbox_messages => 1,
            spaces          => 1,
        },
        'create inserts the space and the category, with one event,'
          . ' outbox message and audit entry'
    );
    is_deeply(
        $ctx->{dbh}->selectcol_arrayref(
            $EVENT_TYPES_SQL, undef, $created->{category_id}
        ),
        [$CREATED],
        'the event is the category.created one'
    );
    is_deeply(
        $ctx->{dbh}
          ->selectall_arrayref( $AUDITS_SQL, undef, $created->{category_id} ),
        [ [ $CREATED, 'category' ] ],
        'the audit entry records the creation and targets the category'
    );
    _purges_category_pages( $ctx, $created->{category_id}, $CREATED );

    return $created;
}

# What the outbox carries is what the cache invalidation handler purges by:
# the category's own pages and, as a category's title or visibility decides
# every page of its threads, the whole public HTML cache.
sub _purges_category_pages {
    my ( $ctx, $category_id, $event_type ) = @_;

    my $payloads =
      $ctx->{dbh}->selectcol_arrayref( $OUTBOX_PAYLOAD_SQL, undef,
        $category_id, $event_type );
    is( scalar @{$payloads}, 1, "one outbox message carries the $event_type" );
    my $tags = GPForum::Worker::Handler::CacheInvalidation->new->handle(
        JSON::MaybeXS->new->decode( $payloads->[0] // '{}' ) )->{tags};
    my %purged = map { $_ => 1 } @{$tags};
    ok(
        $purged{"category:$category_id"}
          && $purged{"forum:category:$category_id"},
        "and its $event_type purges the category's cached pages"
    );
    ok( $purged{$PUBLIC_HTML}, 'and the public HTML cache' );

    return;
}

# The same title again finds the row; a lookup that misses it, as one made
# just before a concurrent create commits does, meets the space and slug key
# and reuses the row. Neither writes a second event or audit entry.
sub _repeat_and_slug_race {
    my ( $ctx, $general ) = @_;

    my $before = _tally($ctx);
    my ( $repeat, $looked ) = _tried( $ctx, 'categories',
        sub { return _create( $ctx, { title => 'General Discussion' } ) } );
    ok( $repeat->{idempotent}, 'create is idempotent for the same space slug' );
    is(
        $repeat->{category_id},
        $general->{category_id},
        'and answers with the stored category'
    );
    is( $looked, 0, 'without trying an INSERT' );
    is_deeply( _tally($ctx), $before, 'an idempotent create writes nothing' );

    my ( $raced, $tries ) = _tried(
        $ctx,
        'categories',
        sub {
            return _create(
                $ctx,
                { title => 'General Discussion' },
                misses => { Category => 1 }
            );
        }
    );
    ok( $raced->{idempotent},
        'a unique category race reuses the existing slug' );
    is(
        $raced->{category_id},
        $general->{category_id},
        'and the existing category'
    );
    is( $tries, 1, 'after the INSERT PostgreSQL refused' );
    is_deeply( _tally($ctx), $before,
        'a unique category race writes no row, event or audit entry' );

    return;
}

sub _edit {
    my ( $ctx, $general ) = @_;

    my $updated = _store($ctx)->update_category(
        {
            actor_user_id => $ctx->{actor_id},
            category_id   => $general->{category_id},
            title         => 'Lounge',
            visibility    => 'members',
        }
    );
    is( $updated->{title},      'Lounge',  'update stores the new title' );
    is( $updated->{visibility}, 'members', 'update stores the new visibility' );
    is( $updated->{slug}, 'general-discussion',
        'update keeps the existing slug' );
    is_deeply(
        $ctx->{dbh}->selectrow_arrayref(
            $CATEGORY_ROW_SQL, undef, $general->{category_id}
        ),
        [ 'Lounge', 'general-discussion', 'members', 2, $NOW ],
        'the row holds the edit at version 2'
    );
    is_deeply(
        $ctx->{dbh}->selectcol_arrayref(
            $EVENT_TYPES_SQL, undef, $general->{category_id}
        ),
        [ $CREATED, $UPDATED ],
        'update writes a category.updated event'
    );
    _purges_category_pages( $ctx, $general->{category_id}, $UPDATED );

    return;
}

# The same edit an hour later changes nothing: no version, no updated_at, no
# event, outbox message or audit entry.
sub _unchanged_edit {
    my ( $ctx, $general ) = @_;

    my $before = _tally($ctx);
    my $same   = _store( $ctx, clock => $LATER )->update_category(
        {
            actor_user_id => $ctx->{actor_id},
            category_id   => $general->{category_id},
            title         => 'Lounge',
            visibility    => 'members',
        }
    );
    ok( $same->{skipped}, 'unchanged category update is skipped' );
    is( $same->{title},      'Lounge',  'unchanged category keeps the title' );
    is( $same->{visibility}, 'members', 'unchanged category keeps visibility' );
    is( $same->{version},    2, 'unchanged category does not bump version' );
    is_deeply(
        $ctx->{dbh}->selectrow_arrayref(
            $CATEGORY_ROW_SQL, undef, $general->{category_id}
        ),
        [ 'Lounge', 'general-discussion', 'members', 2, $NOW ],
        'nor restamp updated_at'
    );
    is_deeply( _tally($ctx), $before,
        'unchanged category writes no event, outbox message or audit entry' );

    return;
}

# Later categories go to the space that exists. A lookup that misses it --
# both the first-space read and the read by slug -- meets the slug key and
# reuses the space rather than adding a second one.
sub _default_space_reused {
    my ( $ctx, $general ) = @_;

    my $announcements = _create( $ctx, { title => 'Announcements' } );
    is( $announcements->{space_id},
        $general->{space_id},
        'a second category reuses the existing default space' );

    my ( $staff, $tries ) = _tried(
        $ctx, 'spaces',
        sub {
            return _create( $ctx, { title => 'Staff' },
                misses => { Space => 2 } );
        }
    );
    ok( !$staff->{idempotent},
        'a unique space race still creates its category' );
    is( $staff->{space_id}, $general->{space_id},
        'a unique space race reuses the default space id' );
    is( $tries,                 1, 'after the INSERT PostgreSQL refused' );
    is( _tally($ctx)->{spaces}, 1, 'and no second space is inserted' );

    return;
}

# Visible categories by position, then title; a soft-deleted one is neither
# listed nor editable.
sub _listing {
    my ($ctx) = @_;

    is_deeply(
        _titles( $ctx, $LIST_LIMIT ),
        [qw(Announcements Lounge Staff)],
        'list orders categories of one position by title'
    );

    my $moved = _store($ctx)->update_category(
        {
            actor_user_id => $ctx->{actor_id},
            category_id   => _category_id( $ctx, 'staff' ),
            position      => $TOP,
        }
    );
    is( $moved->{position}, $TOP,    'update stores a new position' );
    is( $moved->{title},    'Staff', 'and keeps the title it was not given' );
    is_deeply(
        _titles( $ctx, $LIST_LIMIT ),
        [qw(Staff Announcements Lounge)],
        'a lower position lists first'
    );
    is_deeply( _titles( $ctx, 1 ), ['Staff'], 'list applies its limit' );

    my $announcements_id = _category_id( $ctx, 'announcements' );
    $ctx->{dbh}->do( $DELETE_SQL, undef, $announcements_id );
    is_deeply( _titles( $ctx, $LIST_LIMIT ),
        [qw(Staff Lounge)], 'a soft-deleted category is not listed' );
    ok(
        !defined _store($ctx)->update_category(
            {
                actor_user_id => $ctx->{actor_id},
                category_id   => $announcements_id,
                title         => 'Back',
            }
        ),
        'nor can it be edited'
    );

    return;
}

sub _missing_rows {
    my ($ctx) = @_;

    my $before = _tally($ctx);
    ok(
        !defined _create(
            $ctx,
            {
                space_id => GPForum::Infrastructure::Id->new->uuid,
                title    => 'Orphan',
            }
        ),
        'create returns undef when a requested space is missing'
    );
    ok(
        !defined _store($ctx)->update_category(
            {
                actor_user_id => $ctx->{actor_id},
                category_id   => GPForum::Infrastructure::Id->new->uuid,
                title         => 'Gone',
            }
        ),
        'update returns undef when the category is missing'
    );
    is_deeply( _tally($ctx), $before, 'and neither writes anything' );

    # t/145 pinned these with ids that were not uuids, which the fake ORM
    # matched as text and did not find. PostgreSQL refuses the statement,
    # and the admin category routes pass the id on as it came.
    local $TODO = $MALFORMED_TODO;
    ok(
        _answers_undef(
            sub {
                return _create( $ctx,
                    { space_id => 'missing-space', title => 'Orphan' } );
            }
        ),
        'create returns undef for a space id that is not a uuid'
    );
    ok(
        _answers_undef(
            sub {
                return _store($ctx)->update_category(
                    {
                        actor_user_id => $ctx->{actor_id},
                        category_id   => 'missing-category',
                        title         => 'Gone',
                    }
                );
            }
        ),
        'update returns undef for a category id that is not a uuid'
    );

    return;
}

# A minted id that is already stored. When it belongs to another space or
# category, the store mints a new one and creates; when it belongs to the very
# row being created -- committed by an earlier attempt that recorded nothing
# after it -- the store reuses that row and writes what is missing.
sub _space_and_category_collisions {
    my ($ctx) = @_;

    my $ids      = GPForum::Infrastructure::Id->new;
    my $other_id = $ids->uuid;
    $ctx->{dbh}->do( $SPACE_SQL, undef, $other_id, 'other', 'Other' );

    my ( $reminted, $space_tries ) = _tried(
        $ctx, 'spaces',
        sub {
            return _create(
                $ctx,
                { title => 'General Discussion' },
                ids    => [$other_id],
                misses => { Space => 2 }
            );
        }
    );
    ok( !$reminted->{idempotent},
        'a unique space id collision remints and creates' );
    isnt( $reminted->{space_id}, $other_id,
        'the default space gets an id of its own' );
    is(
        $reminted->{space_id},
        _space_id( $ctx, 'general' ),
        'and is the general space'
    );
    is( $space_tries, 2, 'on the INSERT after the one PostgreSQL refused' );
    is( _tally($ctx)->{spaces}, 2, 'beside the other space' );
    is( $reminted->{slug}, 'general-discussion',
        'a unique space id collision still creates this category' );

    my ( $leftover_space, $leftover_tries ) = _tried(
        $ctx, 'spaces',
        sub {
            return _create(
                $ctx,
                { title => 'Leftover Board' },
                ids    => [ $reminted->{space_id} ],
                misses => { Space => 2 }
            );
        }
    );
    is( $leftover_space->{space_id},
        $reminted->{space_id}, 'a leftover space id race reuses this space' );
    ok( !$leftover_space->{idempotent}, 'and still writes this category' );
    is( $leftover_space->{slug}, 'leftover-board', 'under its own slug' );
    is( $leftover_tries,         1, 'after the INSERT PostgreSQL refused' );
    is( _tally($ctx)->{spaces},  2, 'without a second space' );

    my $taken_id = $ids->uuid;
    $ctx->{dbh}->do( $CATEGORY_SQL, undef, $taken_id, $other_id, 'other-board',
        'Other' );
    my ( $category_pk, $category_tries ) = _tried(
        $ctx,
        'categories',
        sub {
            return _create(
                $ctx,
                {
                    space_id => $other_id,
                    title    => 'General Discussion',
                },
                ids => [$taken_id]
            );
        }
    );
    ok( !$category_pk->{idempotent},
        'a unique category id collision remints and creates' );
    is( $category_tries, 2, 'on the INSERT after the one PostgreSQL refused' );
    isnt( $category_pk->{category_id},
        $taken_id, 'the category gets an id of its own' );
    is( $category_pk->{slug}, 'general-discussion',
        'a unique category id collision keeps this slug' );
    is( $category_pk->{space_id},
        $other_id, 'a unique category id collision keeps this space' );

    _category_id_leftover( $ctx, $other_id );

    return;
}

sub _category_id_leftover {
    my ( $ctx, $space_id ) = @_;

    my $leftover_id = GPForum::Infrastructure::Id->new->uuid;
    $ctx->{dbh}->do( $CATEGORY_SQL, undef, $leftover_id, $space_id,
        'orphaned-board', 'Orphaned Board' );
    my $before = _tally($ctx);
    my ( $leftover, $tries ) = _tried(
        $ctx,
        'categories',
        sub {
            return _create(
                $ctx,
                {
                    space_id => $space_id,
                    title    => 'Orphaned Board',
                },
                ids    => [$leftover_id],
                misses => { Category => 1 }
            );
        }
    );
    ok( $leftover->{idempotent},
        'a leftover category id race reuses this category' );
    is( $tries, 1, 'after the INSERT PostgreSQL refused' );
    is( $leftover->{category_id},
        $leftover_id, 'a leftover category id race keeps this category' );
    is( $leftover->{slug}, 'orphaned-board',
        'a leftover category id race keeps this slug' );
    is_deeply(
        _tally($ctx),
        {
            %{$before},
            audit_log       => $before->{audit_log} + 1,
            event_log       => $before->{event_log} + 1,
            outbox_messages => $before->{outbox_messages} + 1,
        },
        'and inserts no category, only the missing event, outbox message'
          . ' and audit entry'
    );
    is_deeply(
        $ctx->{dbh}
          ->selectcol_arrayref( $EVENT_TYPES_SQL, undef, $leftover_id ),
        [$CREATED],
        'the event recorded is its creation'
    );

    return;
}

# True when $code answers undef, false when it answers anything else or dies.
sub _answers_undef {
    my ($code) = @_;

    my $answer = eval { return { value => scalar $code->() } } or return 0;

    return defined $answer->{value} ? 0 : 1;
}

sub _create {
    my ( $ctx, $input, %options ) = @_;

    return _store( $ctx, %options )
      ->create_category( { actor_user_id => $ctx->{actor_id}, %{$input} } );
}

sub _store {
    my ( $ctx, %options ) = @_;

    my $schema =
      $options{misses}
      ? GPForum::Test::RacedSchema->new(
        misses => $options{misses},
        schema => $ctx->{schema},
      )
      : $ctx->{schema};

    return GPForum::Service::Admin::CategoryStore->new(
        clock => GPForum::Test::FixedClock->new(
            iso8601 => $options{clock} // $NOW
        ),
        id_service =>
          GPForum::Test::ScriptedId->new( next_ids => $options{ids} // [] ),
        schema => $schema,
    );
}

# What $code returns, and the INSERT statements into $table it sends, as
# DBIx::Class traces them. A race the store lost shows as an INSERT
# PostgreSQL refused, which leaves no row to count.
sub _tried {
    my ( $ctx, $table, $code ) = @_;

    my $storage = $ctx->{schema}->storage;
    my $inserts = 0;
    $storage->debugcb(
        sub {
            my ( undef, $statement ) = @_;
            if ( $statement =~ /\A INSERT [ ] INTO [ ] "?\Q$table\E"? [ ]/msx )
            {
                $inserts++;
            }
            return;
        }
    );
    $storage->debug(1);
    my $result = $code->();
    $storage->debug(0);
    $storage->debugcb(undef);

    return ( $result, $inserts );
}

sub _titles {
    my ( $ctx, $limit ) = @_;

    return [ map { $_->get_column('title') }
          @{ _store($ctx)->list_categories( { limit => $limit } ) } ];
}

sub _tally {
    my ($ctx) = @_;

    return {
        map {
            $_ => scalar $ctx->{dbh}->selectrow_array("SELECT count(*) FROM $_")
        } @TABLES
    };
}

sub _space_id {
    my ( $ctx, $slug ) = @_;

    return
      scalar $ctx->{dbh}->selectrow_array( $SPACE_BY_SLUG_SQL, undef, $slug );
}

sub _category_id {
    my ( $ctx, $slug ) = @_;

    return
      scalar $ctx->{dbh}
      ->selectrow_array( 'SELECT category_id FROM categories WHERE slug = ?',
        undef, $slug );
}

1;
