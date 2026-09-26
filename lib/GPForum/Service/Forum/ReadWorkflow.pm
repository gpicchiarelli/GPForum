# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::ReadWorkflow;

use strict;
use warnings;

use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

has command_idempotency => undef;
has logger              => undef;
has read_state          => undef;

sub mark_thread_read ( $self, $input ) {
    my $invalid = $self->_missing_command_id($input);
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_mark($input);
}

sub _commanded_mark ( $self, $input ) {
    return $self->_commanded_write(
        {
            actor_id     => $input->{user_id},
            command_id   => $input->{command_id},
            command_type => 'forum.read_marker',
            request      => _mark_request($input),
            run          => sub { return $self->_run_store($input); },
        }
    );
}

sub _commanded_write ( $self, $job ) {
    if ( !$self->command_idempotency ) {
        return $job->{run}->();
    }

    return $self->_idempotent_write($job);
}

sub _idempotent_write ( $self, $job ) {
    my $result = eval { return $self->command_idempotency->result_of($job); };
    if ($EVAL_ERROR) {
        $self->_log_error("forum read marker command log failed: $EVAL_ERROR");
        return _failed_result();
    }

    return $result;
}

sub _run_store ( $self, $input ) {
    my $stored = $self->_eval_store($input);
    if ( $stored->{failed} ) {
        return _failed_result();
    }

    return _stored_mark( $stored->{value} );
}

sub _stored_mark ($value) {
    if ( !$value ) {
        return _failed_result();
    }
    if ( !$value->{ok} ) {
        return $value;
    }

    return _public_marked($value);
}

sub _eval_store ( $self, $input ) {
    my $value = eval {
        return $self->read_state->mark_thread_read( _mark_request($input) );
    };
    if ($EVAL_ERROR) {
        $self->_log_error("forum read marker write failed: $EVAL_ERROR");
        return { failed => 1 };
    }

    return { value => $value };
}

sub _missing_command_id ( $, $input ) {
    if ( length _trim( $input->{command_id} ) ) {
        my $undefined;
        return $undefined;
    }

    return _result(
        errors => { command_id => 'command_id is required' },
        status => 'invalid',
    );
}

sub _public_marked ($marked) {
    my $state = $marked->{read_state} || {};

    return {
        advanced   => $marked->{advanced} ? 1 : 0,
        ok         => 1,
        read_state => {
            last_read_at       => $state->{last_read_at},
            last_read_position => $state->{last_read_position},
            thread_id          => $state->{thread_id},
            user_id            => $state->{user_id},
        },
        status => 'ok',
    };
}

sub _mark_request ($input) {
    return {
        last_read_position => $input->{last_read_position},
        thread_id          => $input->{thread_id},
        user_id            => $input->{user_id},
    };
}

sub _failed_result {
    return _result(
        error  => 'read marker store failed',
        status => 'failed',
    );
}

sub _result (%input) {
    return {
        error  => $input{error},
        errors => $input{errors},
        ok     => ( $input{status} || q{} ) eq 'ok' ? 1 : 0,
        status => $input{status} || 'failed',
        stored => $input{stored},
    };
}

sub _log_error ( $self, $message ) {
    if ( $self->logger ) {
        $self->logger->error($message);
    }

    return;
}

sub _trim ($value) {
    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

1;

__END__

=head1 NAME

GPForum::Service::Forum::ReadWorkflow - Thread read-marker write commands.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $result = $workflow->mark_thread_read(
        {
            command_id         => $command_id,
            last_read_position => $position,
            thread_id          => $thread_id,
            user_id            => $user_id,
        }
    );

=head1 DESCRIPTION

Requires C<command_id> and replays from C<command_log> when the helper is
present. Persistence stays on L<GPForum::Service::Forum::ReadState>. Command
hashes include actor, thread, and position only.

=head1 SUBROUTINES/METHODS

=head2 mark_thread_read

Upserts the viewer's last-read position. Replay returns the recorded result
without a second upsert.

=head1 DIAGNOSTICS

Returns C<invalid>, C<conflict>, or C<failed> statuses instead of throwing
for expected write outcomes.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the read-state helper and command-idempotency helper supplied by the
composition root.

=head1 DEPENDENCIES

Uses L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Read-marker writes remain monotonic at the store. HTTP C<command_id> replay
avoids a second upsert for the same command.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
