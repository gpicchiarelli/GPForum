# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Schema;
use GPForum::Test::AttachmentRow;
use GPForum::Test::CommunityRow;
use GPForum::Test::EngineeringCorrectness::Row;
use GPForum::Test::EventIdempotencyRow;
use GPForum::Test::ForumReadRow;
use GPForum::Test::ModerationRow;
use GPForum::Test::NotificationRow;
use GPForum::Test::OutboxPayloadRow;
use GPForum::Test::PurgeRow;
use GPForum::Test::ReadStateRow;
use GPForum::Test::Row;

our $VERSION = '0.001';

# The row doubles answer the DBIx::Class row surface the application reads,
# with DBIx::Class's rules when they know the result class. Where the rule
# can be read off a real row without a database, the double is held to the
# real row's answer.
const my $REPORT => 'GPForum::Schema::Result::Report';
const my $ACTION => 'GPForum::Schema::Result::ModerationAction';
const my @DBIC_ROW_METHODS => qw(
  delete discard_changes get_column get_columns get_inflated_column
  has_column_loaded in_storage result_source set_column update
);
const my @ROW_DOUBLES => qw(
  GPForum::Test::AttachmentRow
  GPForum::Test::CommunityRow
  GPForum::Test::EngineeringCorrectness::Row
  GPForum::Test::EventIdempotencyRow
  GPForum::Test::ForumReadRow
  GPForum::Test::ModerationRow
  GPForum::Test::NotificationRow
  GPForum::Test::OutboxPayloadRow
  GPForum::Test::PurgeRow
  GPForum::Test::ReadStateRow
);

# No statement runs: new_result builds a row in memory.
my $schema =
  GPForum::Schema->connect('dbi:Pg:dbname=gpforum_no_database;port=1');

subtest 'every shared row double answers the DBIx::Class row methods' => sub {
    for my $class (@ROW_DOUBLES) {
        my @missing = grep { !$class->can($_) } @DBIC_ROW_METHODS;
        is_deeply( \@missing, [], "$class answers them all" );
    }
};

subtest 'with a result class, a name that is not a column is refused' => sub {
    my $real = $schema->resultset('Report')->new_result( { status => 'open' } );
    my $double = GPForum::Test::Row->new(
        data         => { status => 'open' },
        result_class => $REPORT,
    );

    my $real_error   = _error( sub { $real->get_column('no_such_column') } );
    my $double_error = _error( sub { $double->get_column('no_such_column') } );
    like(
        $real_error,
        qr/No [ ] such [ ] column [ ] 'no_such_column'/msx,
        'DBIx::Class refuses it'
    );
    like(
        $double_error,
qr/\A No [ ] such [ ] column [ ] 'no_such_column' [ ] on [ ] \Q$REPORT\E/msx,
        'and so does the double, in the same words'
    );

    is( $double->get_column('status'), 'open', 'a loaded column is read' );
    is(
        $double->get_column('report_id'),
        $real->get_column('report_id'),
        'a column that was not loaded reads as undef, as on the real row'
    );
    ok( !$double->has_column_loaded('report_id'), 'and is not loaded' );
};

subtest 'a column a query added under +as is read through get_column' => sub {
    my $double = GPForum::Test::Row->new(
        data         => { status => 'open', reporter_name => 'ada' },
        result_class => $REPORT,
    );

    is( $double->get_column('reporter_name'),
        'ada', 'it is loaded, so get_column answers it' );
    ok( !$double->can('reporter_name'), 'but it has no accessor' );
    is( { $double->get_columns }->{reporter_name},
        'ada', 'get_columns includes it' );
};

subtest 'column accessors exist for the source columns only' => sub {
    my $real = $schema->resultset('Report')->new_result( { status => 'open' } );
    my $double = GPForum::Test::Row->new(
        data         => { status => 'open' },
        result_class => $REPORT,
    );

    for my $column ( $REPORT->columns ) {
        ok( $double->can($column), "$column has an accessor" );
    }
    is( $double->status, $real->status, 'the accessor reads the column' );
    $double->status('resolved');
    is( $double->get_column('status'), 'resolved', 'and writes it' );
    ok( $double->isa('GPForum::Test::Row'), 'the row is still a row double' );

    my $bare = GPForum::Test::Row->new( data => { status => 'open' } );
    ok( !$bare->can('status'),
        'without a result class the double cannot know the columns' );
    is( $bare->get_column('anything'),
        undef, 'and refuses no name, answering undef' );
};

subtest 'update checks every column, then writes and records' => sub {
    my $data   = { status => 'open', report_id => 'report-1' };
    my $double = GPForum::Test::Row->new(
        data         => $data,
        result_class => $REPORT,
    );

    like(
        _error( sub { $double->update( { status => 'x', hidden_at => 1 } ) } ),
        qr/No [ ] such [ ] column [ ] 'hidden_at'/msx,
        'a change naming a column the source lacks is refused'
    );
    is( $data->{status}, 'open', 'and nothing of it is written' );

    is( $double->update( { status => 'resolved' } ),
        $double, 'update returns the row, as DBIx::Class does' );
    is( $data->{status}, 'resolved',
        'the base double writes into the hash it was given' );
    is_deeply(
        $double->updates,
        [ { status => 'resolved' } ],
        'and records the change'
    );
};

subtest 'delete leaves the row out of storage' => sub {
    my $removed = 0;
    my $row     = GPForum::Test::PurgeRow->new(
        values    => { id => 1 },
        on_delete => sub { $removed++ },
    );

    is( $row->delete, $row, 'delete returns the row' );
    ok( !$row->in_storage,              'which is no longer in storage' );
    ok( $row->deleted && $removed == 1, 'the purge double saw it go' );
    like(
        _error( sub { $row->delete } ),
        qr/\A Not [ ] in [ ] database/msx,
        'a second delete fails, as DBIx::Class fails it'
    );
    like(
        _error( sub { $row->update( { id => 2 } ) } ),
        qr/\A Not [ ] in [ ] database/msx,
        'and so does an update of a deleted row'
    );

    ok( !GPForum::Test::PurgeRow->can('remove'),
        'and it has no remove, which no DBIx::Class row has' );
};

subtest 'an inflated JSON column reads as DBIx::Class reads it' => sub {
    my $metadata = { reason => 'spam' };
    my $real     = $schema->resultset('ModerationAction')
      ->new_result( { metadata => $metadata } );
    my $double = GPForum::Test::Row->new(
        data         => { metadata => $metadata, action_type => 'hide' },
        result_class => $ACTION,
    );

    is_deeply(
        $double->get_inflated_column('metadata'),
        $real->get_inflated_column('metadata'),
        'get_inflated_column is the structure'
    );
    is(
        $double->get_column('metadata'),
        $real->get_column('metadata'),
        'get_column is the JSON text'
    );
    like(
        _error( sub { $real->get_inflated_column('action_type') } ),
        qr/action_type [ ] is [ ] not [ ] an [ ] inflated [ ] column/msx,
        'DBIx::Class refuses to inflate a plain column'
    );
    like(
        _error( sub { $double->get_inflated_column('action_type') } ),
        qr/\A action_type [ ] is [ ] not [ ] an [ ] inflated [ ] column/msx,
        'and so does the double'
    );

    my $text = GPForum::Test::Row->new(
        data         => { metadata => '{"reason":"spam"}' },
        result_class => $ACTION,
    );
    is_deeply( $text->get_inflated_column('metadata'),
        $metadata, 'JSON text is inflated' );
};

subtest 'result_source is the real source, or undef' => sub {
    my $double = GPForum::Test::Row->new( result_class => $REPORT );

    is( $double->result_source->result_class,
        $REPORT, 'with a result class it is that source' );
    ok( $double->result_source->has_column('status'),
        'which answers has_column' );
    is( GPForum::Test::Row->new->result_source,
        undef, 'without one there is none' );
};

subtest 'rows whose resultset keeps its own hash write a new one' => sub {
    for my $class (
        qw(
        GPForum::Test::AttachmentRow
        GPForum::Test::CommunityRow
        GPForum::Test::ModerationRow
        GPForum::Test::ReadStateRow
        )
      )
    {
        my $held = { status => 'open' };
        my $row  = $class->new( data => $held );
        $row->update( { status => 'resolved' } );
        is( $held->{status}, 'open', "$class leaves the held hash alone" );
        is( $row->get_column('status'), 'resolved', 'and reads the change' );
    }

    my $stored = { status => 'open' };
    my $row    = GPForum::Test::NotificationRow->new( data => $stored );
    $row->update( { status => 'read' } );
    is( $stored->{status}, 'read', 'a write-through row writes in place' );
};

subtest 'an event idempotency row is its resultset entry' => sub {
    my %rows = ( 'key-1' => { event_id => 'event-1', completed_at => undef } );
    my $row  = GPForum::Test::EventIdempotencyRow->new(
        key  => 'key-1',
        rows => \%rows,
    );

    is( $row->event_id, 'event-1', 'its accessors read the entry' );
    is( $row->get_column('event_id'), 'event-1', 'and so does get_column' );
    $row->update( { completed_at => 'now' } );
    is( $rows{'key-1'}{completed_at}, 'now', 'update writes the entry' );
    $row->delete;
    ok( !exists $rows{'key-1'}, 'delete removes it' );
};

subtest 'the moderation row refuses a column at create' => sub {
    my $row = GPForum::Test::ModerationRow->new(
        data         => { status => 'open' },
        result_class => $REPORT,
    );

    like(
        _error( sub { $row->assert_columns( 'status', 'hidden_at' ) } ),
        qr/No [ ] such [ ] column [ ] 'hidden_at' [ ] on [ ] \Q$REPORT\E/msx,
        'a column the class lacks is refused'
    );
    is( _error( sub { $row->assert_columns('status') } ),
        q{}, 'a column it has passes' );
};

done_testing();

sub _error ($code) {
    my $error = q{};
    try {
        $code->();
    }
    catch ($caught) {
        $error = "$caught";
    };

    $error =~ s/\A DBIx::Class::\S+ [ ]//msx;

    return $error;
}

1;
