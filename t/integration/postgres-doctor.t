# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::Migrate;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Doctor;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the doctor test';
}

# gpforum doctor's own probes on a real PostgreSQL: the database, its
# schema, the budgets, the readiness report and the outbox, read as the
# command reads them. t/493 holds the words to their doubles; this holds the
# probes to what PostgreSQL answers. The public address is the one probe
# left a double: nothing listens for this test.

my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
local $ENV{GPFORUM_ENV}          = 'development';

subtest 'an empty database: every migration to apply' => sub {
    my $text = _text();
    like(
        $text,
        qr/\N{CHECK MARK} [ ] database: [ ] PostgreSQL [ ] \d+/msx,
        'the database answers, with its version'
    );
    _has( $text, "\N{BALLOT X} schema: ", 'every migration is pending' );
    _has( $text, ' migrations to apply, 001 to ', 'from the first' );
    like( $text, qr/Fix: [ ] gpforum [ ] migrate/msx, 'with the command' );
};

GPForum::Test::PostgresHarness::quietly(
    sub { GPForum::Command::Migrate->new->run('--apply') } );

subtest 'migrated: schema, budgets and readiness agree' => sub {
    my $result = _doctor()->check;
    my %status =
      map { $_->{name} => $_->{status} } @{ $result->{findings}->items };
    is( $status{schema},    'ok', 'the schema is current' );
    is( $status{budgets},   'ok', 'the budgets match the code' );
    is( $status{readiness}, 'ok', 'the rest of the readiness report passes' );
    is( $status{outbox},    'ok', 'nothing waits in the outbox' );
    is( $result->{findings}->exit_status, 0, 'and nothing failed' );
};

subtest 'a message nobody sends is a stopped outbox worker' => sub {
    $database->{dbh}->do(<<'SQL');
INSERT INTO outbox_messages
    (outbox_id, event_id, queue, job_type, idempotency_key, status,
     next_attempt_at, created_at)
VALUES (gen_random_uuid(), gen_random_uuid(), 'mail', 'doctor.test',
        'doctor-test', 'pending', now() - interval '23 minutes',
        now() - interval '23 minutes')
SQL
    _has(
        _text(),
        "\N{BALLOT X} outbox worker: 1 message waiting for 23 min",
        'the oldest message is measured by PostgreSQL'
    );
};

subtest 'a claim its worker stopped renewing is a stopped worker too' => sub {
    $database->{dbh}->do(<<'SQL');
UPDATE outbox_messages
   SET status = 'running', locked_by = 'killed-worker',
       locked_at = now() - interval '24 minutes',
       locked_until = now() - interval '19 minutes'
 WHERE idempotency_key = 'doctor-test'
SQL
    _has(
        _text(),
        "\N{BALLOT X} outbox worker: 1 message waiting for 19 min",
        'waiting since its claim ran out, as the next worker would take it'
    );

    $database->{dbh}->do(<<'SQL');
UPDATE outbox_messages SET locked_until = now() + interval '1 minute'
 WHERE idempotency_key = 'doctor-test'
SQL
    _has(
        _text(),
        "\N{CHECK MARK} outbox worker: nothing waiting",
        'while a claim still held is a worker at work'
    );
};

subtest 'a database it cannot reach is one sentence with its fix' => sub {
    ( my $closed = $database->{dsn} ) =~ s/port=\d+/port=1/msx;
    local $ENV{GPFORUM_DATABASE_DSN} = $closed;
    my $text = _text();
    _has( $text, ':1 (connection refused)', 'the failure, classified' );
    _has(
        $text,
        "\N{BALLOT X} database: cannot reach PostgreSQL at ",
        'in one sentence'
    );
    like( $text, qr/Fix: [ ] start [ ] it [ ] with/msx, 'and its fix' );
    unlike( $text, qr/schema:/msx, 'the checks that need it wait' );
};

GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _doctor {
    return GPForum::Service::Operations::Doctor->new(
        catalog => GPForum::Service::I18N::CliCatalog->new( language => 'en' ),
        file    => undef,
        probes  => { address => sub { return { code => 200 } } },
    );
}

sub _has ( $text, $phrase, $name ) {
    ok( index( $text, $phrase ) >= 0, $name ) or diag $text;

    return;
}

sub _text {
    return _doctor()->check->{findings}->human_text;
}

1;
