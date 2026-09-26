# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Identity::Audit;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Service::Identity::Event;

our $VERSION = '0.001';

has id_service => sub {
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};
has recorder => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
has schema => undef;
has events => sub { return GPForum::Service::Identity::Event->new; };

sub record_registration ( $self, $user, $correlation_id ) {
    $self->recorder->record_event(
        %{ $self->events->registered_envelope( $user, $correlation_id ) } );
    $self->recorder->record_audit(
        %{ $self->events->registered_audit( $user, $correlation_id ) } );

    return;
}

sub record_action ( $self, $input ) {
    $self->recorder->record_audit( %{ $self->events->action($input) } );

    return;
}

sub record_mail ( $self, $input ) {
    $self->recorder->record_event( %{ $self->events->mail_envelope($input) },
        outbox_payload => $self->events->mail_outbox_payload($input), );

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Identity::Audit - Identity domain event and audit writes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $audit = GPForum::Service::Identity::Audit->new( schema => $schema );
    $audit->record_registration( $user, $correlation_id );

=head1 DESCRIPTION

Records registration events/audits, typed identity audit actions, and
identity mail outbox jobs through the shared event recorder. Event and
audit hashes live in L<GPForum::Service::Identity::Event>.

=head1 SUBROUTINES/METHODS

=head2 record_registration

Writes the C<user.registered> event and audit pair.

=head2 record_action

Writes a generic identity audit row.

=head2 record_mail

Writes C<identity.mail.requested> to EventLog and an outbox row whose
payload includes the raw token under C<mail>. EventLog payload is
C<kind> and C<token_id> only.

=head1 DIAGNOSTICS

Recorder failures propagate to the caller.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a DBIx::Class schema accepted by L<GPForum::Infrastructure::EventRecorder>.

=head1 DEPENDENCIES

Uses L<GPForum::Infrastructure::EventRecorder> and
L<GPForum::Service::Identity::Event>. C<GPForum::Infrastructure::Id> is required
lazily unless an C<id_service> is injected.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

HTTP login/logout request persistence remains on
L<GPForum::Service::Identity::SecurityAudit>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
