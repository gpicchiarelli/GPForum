package GPForum::Infrastructure::AuditRecord;

use strict;
use warnings;

use Const::Fast;
use Digest::SHA qw(sha256_hex);
use JSON::MaybeXS;
use Mojo::Base -base;
use POSIX qw(strftime);

our $VERSION = '0.001';

const my $DEFAULT_SCHEMA_VERSION => 1;

has id_service => undef;
has json => sub { return JSON::MaybeXS->new( canonical => 1, utf8 => 1 ); };

sub build {
    my ( $self, $input, $chained_hash ) = @_;

    my $audit = {
        action         => $input->{action},
        actor_id       => $input->{actor_id},
        audit_id       => $self->_audit_id($input),
        correlation_id => $self->_correlation_id($input),
        created_at     => $self->_created_at($input),
        metadata       => $self->_metadata($input),
        previous_hash  => $self->_previous_hash( $input, $chained_hash ),
        record_hash    => q{},
        schema_version => $self->_schema_version($input),
        target_id      => $input->{target_id},
        target_type    => $input->{target_type},
    };
    $audit->{record_hash} = $self->record_hash($audit);

    return $audit;
}

sub verify {
    my ( $self, $audit ) = @_;

    my $payload = $self->payload_from($audit);
    my $hash    = $payload->{record_hash};
    if ( !$self->has_text($hash) ) {
        return 0;
    }

    return $hash eq $self->record_hash($payload) ? 1 : 0;
}

sub payload_from {
    my ( $self, $audit ) = @_;

    return {
        action         => $self->column( $audit, 'action' ),
        actor_id       => $self->column( $audit, 'actor_id' ),
        audit_id       => $self->column( $audit, 'audit_id' ),
        correlation_id => $self->column( $audit, 'correlation_id' ),
        created_at     => $self->column( $audit, 'created_at' ),
        metadata       => $self->column( $audit, 'metadata' ),
        previous_hash  => $self->column( $audit, 'previous_hash' ),
        record_hash    => $self->column( $audit, 'record_hash' ),
        schema_version => $self->column( $audit, 'schema_version' ),
        target_id      => $self->column( $audit, 'target_id' ),
        target_type    => $self->column( $audit, 'target_type' ),
    };
}

sub record_hash {
    my ( $self, $audit ) = @_;

    my %canonical = %{$audit};
    delete $canonical{record_hash};

    return sha256_hex( $self->json->encode( \%canonical ) );
}

sub column {
    my ( $self, $row, $name ) = @_;

    if ( !$row ) {
        return;
    }

    return $self->_row_column( $row, $name );
}

sub has_text {
    my ( undef, $value ) = @_;

    if ( !defined $value ) {
        return 0;
    }

    return length $value ? 1 : 0;
}

sub now_iso8601 {
    return strftime '%Y-%m-%dT%H:%M:%SZ', gmtime time;
}

sub _row_column {
    my ( undef, $row, $name ) = @_;

    if ( ref $row eq 'HASH' ) {
        return $row->{$name};
    }
    if ( $row->can('get_column') ) {
        return $row->get_column($name);
    }

    return;
}

sub _audit_id {
    my ( $self, $input ) = @_;

    return $self->_text_or( $input->{audit_id},
        sub { return $self->id_service->uuid; } );
}

sub _correlation_id {
    my ( $self, $input ) = @_;

    return $self->_text_or( $input->{correlation_id},
        sub { return $self->id_service->uuid; } );
}

sub _created_at {
    my ( $self, $input ) = @_;

    return $self->_text_or( $input->{created_at},
        sub { return $self->now_iso8601; } );
}

sub _schema_version {
    my ( $self, $input ) = @_;

    if ( $self->has_text( $input->{schema_version} ) ) {
        return $input->{schema_version};
    }

    return $DEFAULT_SCHEMA_VERSION;
}

sub _metadata {
    my ( undef, $input ) = @_;

    if ( defined $input->{metadata} ) {
        return $input->{metadata};
    }

    return {};
}

sub _previous_hash {
    my ( $self, $input, $chained_hash ) = @_;

    if ( $self->has_text( $input->{previous_hash} ) ) {
        return $input->{previous_hash};
    }

    return $chained_hash;
}

sub _text_or {
    my ( $self, $value, $fallback ) = @_;

    if ( $self->has_text($value) ) {
        return $value;
    }

    return $fallback->();
}

1;

__END__

=head1 NAME

GPForum::Infrastructure::AuditRecord - Canonical audit hash records.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $audit = $records->build( \%input, $previous_hash );
    ok( $records->verify($audit) );

=head1 DESCRIPTION

Owns audit field defaults, canonical JSON hashing, and hash verification.
It does not persist rows or walk previous audit records.
L<GPForum::Infrastructure::EventRecorder> keeps EventLog, OutboxMessage, and
AuditLog writes plus chain lookup.

=head1 SUBROUTINES/METHODS

=head2 build

Returns a complete audit hash including C<record_hash>. Blank C<previous_hash>
inputs fall back to the chained hash supplied by the recorder.

=head2 verify

True when C<record_hash> matches the canonical payload.

=head2 payload_from

Reads audit fields from a hash or DBIx::Class row.

=head2 record_hash

Hashes the canonical audit payload without C<record_hash>.

=head2 column

Reads a named field from a hash or row.

=head2 has_text

True when the value is defined and non-empty.

=head2 now_iso8601

Returns the current UTC timestamp used when C<created_at> is omitted.

=head1 DIAGNOSTICS

Missing hashes fail verification. Persistence errors stay in the recorder.

=head1 CONFIGURATION AND ENVIRONMENT

Requires an id service only when C<audit_id> or C<correlation_id> are omitted.

=head1 DEPENDENCIES

Uses L<Digest::SHA>, L<JSON::MaybeXS>, and L<POSIX>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Hashing stays here. L<GPForum::Infrastructure::EventRecorder> serializes
previous-hash lookup with a transaction advisory lock when a database handle
is available.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
