# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Identity::SecurityAudit;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Service::Clock;
use GPForum::Service::Identity::Event;

our $VERSION = '0.001';

has clock      => sub { return GPForum::Service::Clock->new; };
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

sub record_login_request ( $self, $input ) {
    return $self->_record(
        $self->events->login_request_audit( $self->_timed($input) ) );
}

sub record_logout_request ( $self, $input ) {
    return $self->_record(
        $self->events->logout_request_audit( $self->_timed($input) ) );
}

sub _timed ( $self, $input ) {
    return { %{$input}, created_at => $self->clock->now_iso8601, };
}

sub _record ( $self, $audit ) {
    my $row = $self->recorder->record_audit( %{$audit} );

    return { ok => 1, audit => $row };
}

1;

__END__

=head1 NAME

GPForum::Service::Identity::SecurityAudit - Write login and logout request audits to the AuditLog.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $audit = GPForum::Service::Identity::SecurityAudit->new(
        schema => $schema,
    );
    $audit->record_login_request(
        {
            actor_id        => $user_id,
            identifier      => $submitted_identifier,
            outcome         => 'accepted',
            request_address => $remote_address,
        }
    );
    $audit->record_logout_request(
        { actor_id => $user_id, request_address => $remote_address } );

=head1 DESCRIPTION

Persists the AuditLog rows for HTTP login and logout requests.
L<GPForum::Service::Identity::Event> builds the row (it hashes the
identifier and the request address with SHA-256, so neither is stored in
clear); this class stamps it with the clock's current time and hands it to
L<GPForum::Infrastructure::EventRecorder>, which chains it onto the audit
hash chain.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor. C<schema> is required for writes; C<clock>,
C<id_service>, C<recorder> and C<events> default to
L<GPForum::Service::Clock>, L<GPForum::Infrastructure::Id>, an
L<GPForum::Infrastructure::EventRecorder> on the schema and
L<GPForum::Service::Identity::Event>.

=head2 record_login_request

Takes a hash reference with C<actor_id>, C<identifier>, C<request_address>
and an optional C<outcome> (C<accepted> when absent). Records an
C<identity.login.requested> audit and returns
C<< { ok => 1, audit => $audit } >>, where C<$audit> is the hash the
recorder stored.

=head2 record_logout_request

Takes a hash reference with C<actor_id> and C<request_address>. Records an
C<identity.logout.requested> audit and returns
C<< { ok => 1, audit => $audit } >>.

=head1 DIAGNOSTICS

Nothing is returned as a failure: errors from the recorder or the database
propagate to the caller.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::EventRecorder>, L<GPForum::Infrastructure::Id>,
L<GPForum::Service::Clock>, L<GPForum::Service::Identity::Event>.

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
