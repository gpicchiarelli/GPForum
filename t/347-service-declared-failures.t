# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Service::Attachment::Scanner;
use GPForum::Service::Operations::LocalCache;
use GPForum::Service::Operations::MetricsSnapshot;
use GPForum::Service::Operations::QueryBudget;
use GPForum::Service::Operations::SharedCache;
use GPForum::Service::Outbox::FailureType;
use GPForum::Service::Search::Indexer;
use GPForum::Test::Antivirus;
use GPForum::Test::AttachmentFixtures;
use GPForum::Test::SearchSchema;

our $VERSION = '0.001';

const my $PNG_BYTES      => pack( 'H*', '89504e470d0a1a0a' ) . 'attachment';
const my $EXCESS_QUERIES => 1000;
const my @OPTIONAL_SECTIONS => qw(
  db_query_stats os os_features os_preflight os_processes os_sockets
  realtime realtime_listener runtime_enforcement security
);

# The WP4 services raise GPForum::X classes where they croaked strings: the
# outbox reads the declared failure_type (X::Unavailable is retried as a
# transport failure, X::Argument, X::Config and X::Check are permanent), and
# the CLI and the controllers can tell a broken call from a configuration
# that is wrong. The messages did not change, so each test that matched one
# still passed when the class was taken away again; these pin the class.
my $types = GPForum::Service::Outbox::FailureType->new;

# The attachment scanner retries what it cannot read or scan.
{
    my $fixture = GPForum::Test::AttachmentFixtures->build(
        antivirus => GPForum::Test::Antivirus->new( immediate => 0 ) );
    my $attachment_id = _upload($fixture);
    my $key =
      $fixture->{store}
      ->record->column( $fixture->{store}->find_attachment($attachment_id),
        'object_key' );
    $fixture->{storage}->delete_object($key);

    my $unreadable = _error_of(
        sub {
            GPForum::Service::Attachment::Scanner->new(
                antivirus => GPForum::Test::Antivirus->new,
                storage   => $fixture->{storage},
                store     => $fixture->{store},
            )->scan($attachment_id);
        }
    );
    isa_ok( $unreadable, 'GPForum::X::Unavailable',
        'a stored object that cannot be read' );
    like(
        "$unreadable",
        qr/\Acannot [ ] read [ ] stored [ ] object/msx,
        'with the message it had'
    );
    ok( defined $unreadable->cause, 'and the read error as its cause' );
    is( $types->classify($unreadable),
        'transport', 'which the outbox retries as a transport failure' );
}
{
    my $fixture = GPForum::Test::AttachmentFixtures->build(
        antivirus => GPForum::Test::Antivirus->new( immediate => 0 ) );
    my $attachment_id = _upload($fixture);
    my $unscanned     = _error_of(
        sub {
            GPForum::Service::Attachment::Scanner->new(
                antivirus => GPForum::Test::Antivirus->new(
                    verdict => {
                        engine => 'Fake 1/1',
                        error  => 'timeout',
                        status => 'error',
                    }
                ),
                storage => $fixture->{storage},
                store   => $fixture->{store},
            )->scan($attachment_id);
        }
    );
    isa_ok( $unscanned, 'GPForum::X::Unavailable',
        'an antivirus that cannot scan' );
    like(
        "$unscanned",
        qr/antivirus [ ] could [ ] not [ ] scan/msx,
        'with the message it had'
    );
}

# An intent under another id but a stored attachment's object key finishes
# that attachment instead of failing on the object key's unique index.
{
    my $fixture = GPForum::Test::AttachmentFixtures->build;
    my $stored  = _upload($fixture);
    my $created = scalar @{ $fixture->{attachments}->created };
    my %intent  = %{ $fixture->{attachments}->created->[0] };
    $intent{attachment_id} = 'attachment-reissued';

    my $replayed = $fixture->{store}->create_intent( \%intent );
    ok( $replayed->{skipped}, 'an object key taken by a stored attachment' );
    is(
        $fixture->{store}
          ->record->column( $replayed->{attachment}, 'attachment_id' ),
        $stored,
        'answers with that attachment'
    );
    is( scalar @{ $fixture->{attachments}->created },
        $created, 'and inserts no second one' );
}

# The query budget's hard-fail mode is a check that failed.
{
    my $breach = _error_of(
        sub {
            GPForum::Service::Operations::QueryBudget->new->enforce(
                'thread_view',
                { queries => $EXCESS_QUERIES, transactions => 1 } );
        }
    );
    isa_ok( $breach, 'GPForum::X::Check', 'a query budget breach' );
    is(
        "$breach",
        'query budget exceeded:thread_view:queries',
        'with the message it had'
    );
}

# A rebuild cursor the indexer cannot follow is a broken call.
{
    my $indexer = GPForum::Service::Search::Indexer->new(
        schema => GPForum::Test::SearchSchema->new );
    my $type =
      _error_of(
        sub { $indexer->rebuild_batch( { entity_type => 'bogus' } ) } );
    isa_ok( $type, 'GPForum::X::Argument', 'an unknown rebuild entity type' );
    is( "$type", 'unknown rebuild entity type: bogus', 'named' );
    my $stage = _error_of(
        sub {
            $indexer->rebuild_batch(
                { entity_type => 'thread', stage => 'bogus' } );
        }
    );
    isa_ok( $stage, 'GPForum::X::Argument', 'an unknown rebuild stage' );
    is( "$stage", 'unknown rebuild stage: bogus', 'named' );
}

# The caches: a key that is missing breaks the call, a size or a GlifiStore
# URL that is missing or malformed is configuration.
{
    my %expected = (
        'LocalCache without a key' => [
            'GPForum::X::Argument',
            sub { GPForum::Service::Operations::LocalCache->new->get(q{}) },
        ],
        'LocalCache with no room' => [
            'GPForum::X::Config',
            sub {
                GPForum::Service::Operations::LocalCache->new(
                    max_entries => 0 )->put( 'key', 1 );
            },
        ],
        'SharedCache without a key' => [
            'GPForum::X::Argument',
            sub {
                GPForum::Service::Operations::SharedCache->new->invalidate(q{});
            },
        ],
        'SharedCache without a URL' => [
            'GPForum::X::Config',
            sub {
                GPForum::Service::Operations::SharedCache->connect_required(
                    {} );
            },
        ],
        'SharedCache with a malformed URL' => [
            'GPForum::X::Config',
            sub {
                GPForum::Service::Operations::SharedCache->parse_endpoint(
                    'ftp://cache');
            },
        ],
    );
    for my $case ( sort keys %expected ) {
        my ( $class, $code ) = @{ $expected{$case} };
        isa_ok( _error_of($code), $class, $case );
    }
}

# A metrics scrape without its optional collaborators reports their sections
# empty, not missing: /metrics renders each one as a hash.
{
    my $snapshot = GPForum::Service::Operations::MetricsSnapshot->new->collect;
    is_deeply(
        { map { $_ => $snapshot->{$_} } @OPTIONAL_SECTIONS },
        { map { $_ => {} } @OPTIONAL_SECTIONS },
        'every optional section is an empty hash without its collaborator'
    );
}

done_testing();

sub _upload {
    my ($fixture) = @_;

    my $uploaded = $fixture->{pipeline}->upload_and_link(
        {
            actor_user_id     => 'user-1',
            content           => $PNG_BYTES,
            media_type        => 'image/png',
            original_filename => 'photo.png',
            target_id         => 'post-99',
            target_type       => 'post',
        }
    );

    return $uploaded->{attachment}{attachment_id};
}

sub _error_of {
    my ($code) = @_;

    my $failure;
    try {
        $code->();
    }
    catch ($error) {
        $failure = $error;
    };

    return $failure;
}

1;
