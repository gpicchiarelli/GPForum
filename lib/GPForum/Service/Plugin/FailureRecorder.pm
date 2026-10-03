# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Plugin::FailureRecorder;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Infrastructure::Id;

our $VERSION = '0.001';

const my $ID_CONSTRAINT => 'plugin_failures_pkey';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Infrastructure::Id->new; };
has schema     => undef;

sub record_failure ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_failure($input); },
      );
    if ($created) {
        return $created;
    }

    return $self->_failure_after_conflict( $input, $error );
}

sub _insert_failure ( $self, $input ) {
    my $failure = {
        plugin_failure_id => $self->id_service->uuid,
        plugin_id         => $input->{plugin_id},
        hook_name         => $input->{hook_name},
        error_class       => $input->{error_class},
        error_message     => $input->{error_message},
        context           => $input->{context} || {},
        created_at        => $self->clock->now_iso8601,
    };
    $self->schema->resultset('PluginFailure')->create($failure);

    return $failure;
}

sub _failure_after_conflict ( $self, $input, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( index( $error, $ID_CONSTRAINT ) < 0 ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_retry_failure_id($input);
}

sub _retry_failure_id ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_failure($input); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

1;

__END__

=head1 NAME

GPForum::Service::Plugin::FailureRecorder - Store a failed plugin hook call in plugin_failures.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $recorder =
      GPForum::Service::Plugin::FailureRecorder->new( schema => $schema );

    my $failure = $recorder->record_failure(
        {
            context       => { payload_id => $post_id },
            error_class   => 'timeout',
            error_message => 'callback exceeded timeout',
            hook_name     => 'post.created',
            plugin_id     => $plugin_id,
        }
    );

=head1 DESCRIPTION

Inserts one C<plugin_failures> row for each failed hook call, for
L<GPForum::Service::Plugin::HookDispatcher>: a fresh uuid, the plugin id,
the hook name, the error's class and message, a context hash and the time.
Every call is a new failure; nothing is merged. If the minted id collides
with an existing row's primary key, the insert is retried once with a new
id.

=head1 SUBROUTINES/METHODS

=head2 record_failure

Takes a hash reference with C<plugin_id>, C<hook_name>, C<error_class>,
C<error_message> and an optional C<context> hash (empty when absent).
Returns the row as inserted: C<plugin_failure_id>, those five values and
C<created_at>.

=head1 DIAGNOSTICS

An error from the insert other than a collision on the failure id, or a
second collision, is rethrown with C<croak>.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::Infrastructure::Id>,
L<GPForum::Service::Clock>.

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
