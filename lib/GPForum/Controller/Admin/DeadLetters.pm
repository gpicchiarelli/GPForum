# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Admin::DeadLetters;

use strict;
use warnings;

use Mojo::Base 'GPForum::Controller::Admin::Base', -signatures;

our $VERSION = '0.001';

# Not behind a danger confirmation: a replay takes nothing away. It enqueues
# the work again, and the handlers it reaches are idempotent (ADR 0056).
sub replay ($self) {
    my $actor_user_id = $self->authorized_write_user_id;
    if ( !$actor_user_id ) {
        return;
    }

    my $result = $self->gp_admin_workflow->replay_dead_letter(
        {
            actor_user_id  => $actor_user_id,
            command_id     => $self->command_id_param,
            dead_letter_id => $self->param('dead_letter_id'),
        }
    );
    my $failure = $self->write_failure($result);
    return $failure if $failure;

    return $self->dead_letter_replay_response(
        $self->admin_access->dead_letter_replayed_status,
        $result->{stored} );
}

1;

__END__

=head1 NAME

GPForum::Controller::Admin::DeadLetters - Replay a dead letter from the console.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    POST /admin/dead-letters/:dead_letter_id/replay

=head1 DESCRIPTION

The console side of ADR 0056's replay: an administrator puts a dead letter's
work back in the queue from C</admin/jobs>. The work itself is
L<GPForum::Service::Outbox::DeadLetterReplay>'s.

=head1 SUBROUTINES/METHODS

=head2 replay

Replays one dead letter under the request's command id; redirects to the jobs
page, or answers JSON. 404 for an unknown dead letter, 409 for one that was
already replayed or cannot be.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Controller::Admin::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
