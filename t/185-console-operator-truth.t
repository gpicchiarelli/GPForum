# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Operations::CommandIdempotency;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::Schema;

our $VERSION = '0.001';

const my $SHARED_ID => '11111111-1111-1111-1111-111111111111';
const my $OTHER_ID  => '22222222-2222-2222-2222-222222222222';

# The idempotency key is the command id alone -- no action, no route. A thread
# report renders a hide form and a lock form at the same time, and both used to
# carry the same command_id, so the second submission found the first command's
# row and replayed its response without running the lock. The moderator saw
# success and the thread stayed unlocked.
sub _executed_actions {
    my (@command_ids) = @_;

    my $service = GPForum::Service::Operations::CommandIdempotency->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
        schema     => GPForum::Test::Schema->new,
    );

    my @ran;
    my @actions = ( 'thread.hide', 'thread.lock' );
    for my $index ( 0 .. $#actions ) {
        my $action = $actions[$index];
        $service->run(
            {
                command_id => $command_ids[$index],
                request    => { action => $action },
            },
            sub { push @ran, $action; return { ok => 1 }; },
            sub { my ($value) = @_;   return $value; },
        );
    }

    return \@ran;
}

is_deeply( _executed_actions( $SHARED_ID, $SHARED_ID ),
    ['thread.hide'],
    'one command id for two actions silently drops the second' );

is_deeply(
    _executed_actions( $SHARED_ID, $OTHER_ID ),
    [ 'thread.hide', 'thread.lock' ],
    'distinct command ids run both moderation actions'
);

# The template must therefore not spend one id on both forms.
my $reports = _slurp('templates/moderation/reports.html.ep');

like(
    $reports,
    qr/moderation_thread_lock.*?lock_command_id/msx,
    'the lock form carries its own command id'
);

# A reporter's words must not become the moderator's audited justification.
unlike(
    $reports,
    qr/name="reason" \s+ value="<%= \s* [\$]report->[{]reason[}]/msx,
    'the staff reason field is not pre-filled with reporter text'
);
like(
    $reports,
    qr/moderation[.]staff_reason/msx,
    'the staff reason field is labelled as the moderator\'s own'
);

# The dashboard counted a list the reader had already truncated.
my $dashboard = _slurp('templates/admin/dashboard.html.ep');

unlike(
    $dashboard,
    qr/scalar \s+ [\@][{] \s* [\$]summary->[{]async[}]/msx,
    'the dashboard does not count a truncated list'
);
like( $dashboard, qr/dead_letter_total/msx,
    'the dashboard reads a real dead-letter total' );
like( $dashboard, qr/outbox_message_total/msx,
    'the dashboard reads a real outbox total' );

sub _slurp {
    my ($path) = @_;

    open my $handle, '<', $path or croak "open $path: $ERRNO";
    local $INPUT_RECORD_SEPARATOR = undef;
    my $text = <$handle>;
    close $handle or croak "close $path: $ERRNO";

    return $text;
}

done_testing();

1;
