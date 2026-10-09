# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::Id;
use GPForum::Service::Attachment::IntentBuilder;
use GPForum::Service::Attachment::Store;
use GPForum::Test::FixedClock;
use GPForum::Test::PgDatabase;
use GPForum::Test::RacedSchema;

our $VERSION = '0.001';

const my $NOW_EPOCH   => 1_779_537_600;
const my $VALID_BYTES => 4_096;
const my $USER_SQL => join q{ },
  'INSERT INTO users (id, username, display_name, email_normalized,',
  q{password_hash, status) VALUES (?, ?, ?, ?, 'x', 'active')};
const my $ATTACHMENT_SQL => join q{ },
  'SELECT owner_user_id, object_key FROM attachments',
  'WHERE attachment_id = ?';

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run against PostgreSQL';
}

# An intent whose id PostgreSQL refuses (attachments_pkey) although neither
# look found the row holding it -- the look before the INSERT and the one
# after the conflict both raced, as a snapshot taken before the holder
# committed sees it -- is reissued under a fresh id and object key, as one
# whose look found another attachment there is. Retried under the same id it
# could only conflict again, and the upload failed. t/integration/
# postgres-attachments.t races only the first look.
my $database = GPForum::Test::PgDatabase->fresh;
my $dbh      = $database->dbh;
my $ids      = GPForum::Infrastructure::Id->new;
my $clock    = GPForum::Test::FixedClock->new( epoch => $NOW_EPOCH );
my %user     = map { $_ => _user($_) } qw(holder uploader);

my $holder = $ids->uuid;
GPForum::Service::Attachment::Store->new(
    clock      => $clock,
    id_service => $ids,
    schema     => $database->schema,
)->create_intent( _intent( $user{holder}, 'held', $holder ) );

my $store = GPForum::Service::Attachment::Store->new(
    clock      => $clock,
    id_service => $ids,
    schema     => GPForum::Test::RacedSchema->new(
        misses => { Attachment => 2 },
        schema => $database->schema,
    ),
);
my ( $created, $error );
try {
    $created =
      $store->create_intent( _intent( $user{uploader}, 'raced', $holder ) );
}
catch ($caught) {
    $error = "$caught";
};
is( $error, undef, 'an id race whose looks both missed does not fail' );
my $id = $created ? $created->{attachment}->get_column('attachment_id') : undef;
ok(
    defined $id && GPForum::Infrastructure::Id->is_uuid($id) && $id ne $holder,
    'it reissues the id'
);
is_deeply(
    [ $id ? $dbh->selectrow_array( $ATTACHMENT_SQL, undef, $id ) : () ],
    [ $user{uploader}, "attachments/$user{uploader}/" . ( $id // q{} ) ],
    'and the object key, for the uploader'
);
is_deeply(
    [ $dbh->selectrow_array( $ATTACHMENT_SQL, undef, $holder ) ],
    [ $user{holder}, "attachments/$user{holder}/$holder" ],
    'and leaves the attachment holding the id alone'
);

done_testing();

sub _user {
    my ($name) = @_;

    my $user_id = $ids->uuid;
    $dbh->do( $USER_SQL, undef, $user_id, $name, ucfirst $name,
        "$name\@example.test" );

    return $user_id;
}

sub _intent {
    my ( $owner, $name, $attachment_id ) = @_;

    my $intent = GPForum::Service::Attachment::IntentBuilder->new(
        clock      => $clock,
        id_service => $ids,
    )->build_intent(
        {
            byte_size         => $VALID_BYTES,
            checksum          => $name,
            media_type        => 'image/png',
            original_filename => "$name.png",
            owner_user_id     => $owner,
        }
    );

    return {
        %{$intent},
        attachment_id => $attachment_id,
        object_key    => "attachments/$owner/$attachment_id",
    };
}

1;
