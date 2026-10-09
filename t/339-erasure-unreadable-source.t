# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Privacy::DeletionWorkflow;
use GPForum::Test::EngineeringCorrectness::Schema;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;

our $VERSION = '0.001';

const my $NOW => '2026-05-23T12:00:00Z';

# An erasure revokes the member's credentials and sessions in the
# transaction that anonymizes the account. A source it cannot read fails the
# erasure, which rolls back: the account is not anonymized behind sessions
# still signed in, and the job runs again. The workflow skipped such a
# source, and completed the erasure without revoking its rows.
my $schema  = _seeded_schema();
my $erasure = GPForum::Service::Privacy::DeletionWorkflow->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => $schema,
);

my $read_resultset = \&GPForum::Test::EngineeringCorrectness::Schema::resultset;
my ( $completed, $error );
{
    local *GPForum::Test::EngineeringCorrectness::Schema::resultset =
      sub ( $self, $name ) {
        if ( $name eq 'Session' ) {
            die "relation \"sessions\" cannot be read\n";
        }
        return $read_resultset->( $self, $name );
      };
    try {
        $completed = $erasure->complete_job( 'job-1', 'worker-1' );
    }
    catch ($caught) {
        $error = $caught;
    };
}

like(
    $error // q{},
    qr/"sessions" [ ] cannot [ ] be [ ] read/msx,
    'an erasure that cannot read the sessions fails'
);
ok( !defined $completed, 'rather than completing without them' );
is( _column( 'User', 'user-1', 'deleted_at' ),
    undef, 'the account is not anonymized' );
is( _column( 'Credential', 'credential-1', 'revoked_at' ),
    undef, 'its credentials are not revoked' );
is( _column( 'ErasureJob', 'job-1', 'status' ),
    'pending', 'and the job is left to run again' );

my $retried = $erasure->complete_job( 'job-1', 'worker-1' );
ok( $retried && $retried->{ok},
    'the job completes once the sessions can be read' );
is( _column( 'Session', 'session-1', 'revoked_at' ),
    $NOW, 'revoking the session' );
is( _column( 'User', 'user-1', 'deleted_at' ),
    $NOW, 'with the account anonymized' );

done_testing();

sub _column ( $source, $id, $name ) {
    my $row = $schema->resultset($source)->find($id);

    return $row ? $row->get_column($name) : undef;
}

sub _seeded_schema {
    my $seeded = GPForum::Test::EngineeringCorrectness::Schema->new;
    $seeded->resultset('User')->create(
        {
            deleted_at       => undef,
            display_name     => 'Member One',
            email_normalized => 'member@example.test',
            status           => 'active',
            user_id          => 'user-1',
        }
    );
    $seeded->resultset('Credential')->create(
        {
            credential_id => 'credential-1',
            revoked_at    => undef,
            user_id       => 'user-1',
        }
    );
    $seeded->resultset('Session')->create(
        {
            revoked_at => undef,
            session_id => 'session-1',
            user_id    => 'user-1',
        }
    );
    $seeded->resultset('DeletionRequest')->create(
        {
            completed_at        => undef,
            created_at          => $NOW,
            deletion_request_id => 'delete-1',
            reason              => 'account cleanup',
            request_type        => 'anonymize',
            requester_user_id   => 'user-1',
            resource_id         => 'user-1',
            resource_type       => 'user',
            status              => 'approved',
        }
    );
    $seeded->resultset('ErasureJob')->create(
        {
            completed_at        => undef,
            deletion_request_id => 'delete-1',
            erasure_job_id      => 'job-1',
            last_error          => undef,
            scheduled_at        => $NOW,
            status              => 'pending',
        }
    );

    return $seeded;
}

1;
