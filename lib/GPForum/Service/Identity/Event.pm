package GPForum::Service::Identity::Event;

use strict;
use warnings;

use Const::Fast;
use Digest::SHA qw(sha256_hex);
use Mojo::Base -base;

our $VERSION = '0.001';

const my $USER_AGGREGATE   => 'user';
const my $SCHEMA_VERSION   => 1;
const my $REGISTERED       => 'user.registered';
const my $LOGIN_REQUESTED  => 'identity.login.requested';
const my $LOGOUT_REQUESTED => 'identity.logout.requested';
const my $TARGET_IDENTITY  => 'identity';
const my $TARGET_SESSION   => 'session';
const my $OUTCOME_ACCEPTED => 'accepted';

sub registered_envelope {
    my ( undef, $user, $correlation_id ) = @_;

    return {
        actor_id          => $user->{id},
        aggregate_id      => $user->{id},
        aggregate_type    => $USER_AGGREGATE,
        aggregate_version => $SCHEMA_VERSION,
        causation_id      => undef,
        correlation_id    => $correlation_id,
        event_type        => $REGISTERED,
        idempotency_key   => join( q{:}, $REGISTERED, $user->{id} ),
        payload           => { username => $user->{username} },
        schema_version    => $SCHEMA_VERSION,
    };
}

sub registered_audit {
    my ( undef, $user, $correlation_id ) = @_;

    return {
        action         => $REGISTERED,
        actor_id       => $user->{id},
        correlation_id => $correlation_id,
        metadata       => { username => $user->{username} },
        schema_version => $SCHEMA_VERSION,
        target_id      => $user->{id},
        target_type    => $USER_AGGREGATE,
    };
}

sub action {
    my ( undef, $input ) = @_;

    return {
        action         => $input->{action},
        actor_id       => $input->{actor_id},
        metadata       => $input->{metadata} || {},
        schema_version => $SCHEMA_VERSION,
        target_id      => $input->{target_id},
        target_type    => $input->{target_type},
    };
}

sub login_request_audit {
    my ( undef, $input ) = @_;

    return {
        action     => $LOGIN_REQUESTED,
        actor_id   => $input->{actor_id},
        created_at => $input->{created_at},
        metadata   => {
            identifier_hash      => _hash_value( $input->{identifier} ),
            outcome              => $input->{outcome} || $OUTCOME_ACCEPTED,
            request_address_hash => _hash_value( $input->{request_address} ),
        },
        previous_hash  => undef,
        record_hash    => q{},
        schema_version => $SCHEMA_VERSION,
        target_id      => undef,
        target_type    => $TARGET_IDENTITY,
    };
}

sub logout_request_audit {
    my ( undef, $input ) = @_;

    return {
        action     => $LOGOUT_REQUESTED,
        actor_id   => $input->{actor_id},
        created_at => $input->{created_at},
        metadata   => {
            request_address_hash => _hash_value( $input->{request_address} ),
        },
        previous_hash  => undef,
        record_hash    => q{},
        schema_version => $SCHEMA_VERSION,
        target_id      => undef,
        target_type    => $TARGET_SESSION,
    };
}

sub _hash_value {
    my ($value) = @_;

    my $digest;
    if ( defined $value && length $value ) {
        $digest = sha256_hex($value);
    }

    return $digest;
}

1;

__END__

=head1 NAME

GPForum::Service::Identity::Event - Identity event and audit hashes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $event = $events->registered_envelope( $user, $correlation_id );

=head1 DESCRIPTION

Owns C<user.registered> EventLog envelopes, registration AuditLog hashes,
generic identity audit arguments, and login/logout request AuditLog hashes.
It does not persist rows. L<GPForum::Service::Identity::Audit> still writes
EventLog, OutboxMessage, and AuditLog.
L<GPForum::Service::Identity::SecurityAudit> still writes login and logout
request audits.

=head1 SUBROUTINES/METHODS

=head2 registered_envelope

Returns EventLog arguments for a registration.

=head2 registered_audit

Returns AuditLog arguments for a registration.

=head2 action

Returns AuditLog arguments for a typed identity action.

=head2 login_request_audit

Returns AuditLog arguments for an HTTP login request. Identifiers and
request addresses are SHA-256 hashed; empty values stay undefined.

=head2 logout_request_audit

Returns AuditLog arguments for an HTTP logout request. Request addresses
are SHA-256 hashed; empty values stay undefined.

=head1 DIAGNOSTICS

None. Persistence errors stay in L<GPForum::Service::Identity::Audit> and
L<GPForum::Service::Identity::SecurityAudit>.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<Digest::SHA>, and L<Mojo::Base>.

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
