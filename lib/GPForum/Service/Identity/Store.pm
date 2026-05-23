package GPForum::Service::Identity::Store;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $USER_AGGREGATE => 'user';

has schema     => undef;
has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };

sub create_registration {
    my ( $self, $registration ) = @_;

    my $errors = $self->_duplicate_errors( $registration->{user} );

    return { ok => 0, errors => $errors }
      if keys %{$errors};

    my $result = $self->schema->txn_do(
        sub {
            return $self->_insert_registration($registration);
        }
    );

    return { ok => 1, user => $result->{user} };
}

sub _duplicate_errors {
    my ( $self, $user ) = @_;

    my %errors;

    if ( $self->schema->resultset('User')
        ->find( { username => $user->{username} } ) )
    {
        $errors{username} = 'username is already registered';
    }

    if ( $self->schema->resultset('User')
        ->find( { email_normalized => $user->{email_normalized} } ) )
    {
        $errors{email} = 'email is already registered';
    }

    return \%errors;
}

sub _insert_registration {
    my ( $self, $registration ) = @_;

    my $user       = $registration->{user};
    my $credential = $registration->{credential};

    my $created_user = $self->schema->resultset('User')->create($user);

    $self->schema->resultset('Credential')->create(
        {
            id          => $self->id_service->uuid,
            user_id     => $user->{id},
            type        => $credential->{type},
            secret_hash => $credential->{secret_hash},
        }
    );

    $self->_record_event($user);
    $self->_record_audit($user);

    return { user => $created_user };
}

sub _record_event {
    my ( $self, $user ) = @_;

    $self->schema->resultset('EventLog')->create(
        {
            event_id       => $self->id_service->uuid,
            event_type     => 'user.registered',
            aggregate_type => $USER_AGGREGATE,
            aggregate_id   => $user->{id},
            actor_id       => $user->{id},
            payload        => { username => $user->{username} },
            metadata       => {},
        }
    );

    return;
}

sub _record_audit {
    my ( $self, $user ) = @_;

    $self->schema->resultset('AuditLog')->create(
        {
            audit_id    => $self->id_service->uuid,
            action      => 'user.registered',
            actor_id    => $user->{id},
            target_type => $USER_AGGREGATE,
            target_id   => $user->{id},
            metadata    => { username => $user->{username} },
        }
    );

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Identity::Store - Identity persistence boundary.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $store = GPForum::Service::Identity::Store->new(schema => $schema);

=head1 DESCRIPTION

Persists identity workflow records through DBIx::Class resultsets while keeping
controllers and ORM result classes free of workflow logic.

=head1 SUBROUTINES/METHODS

=head2 create_registration

Persists a prepared registration, password credential, event, and audit record.

=head1 DIAGNOSTICS

Storage errors are reported by the schema layer.

=head1 CONFIGURATION AND ENVIRONMENT

Receives a schema object from application wiring.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<Mojo::Base>, L<GPForum::Service::Clock>, and
L<GPForum::Service::Id>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

This service currently handles registration persistence only.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
