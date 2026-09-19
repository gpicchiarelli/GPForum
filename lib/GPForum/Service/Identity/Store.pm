package GPForum::Service::Identity::Store;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Service::Clock;
use GPForum::Service::Identity::AccountStore;
use GPForum::Service::Identity::Audit;
use GPForum::Service::Identity::AuthStore;
use GPForum::Service::Identity::CredentialStore;
use GPForum::Service::Identity::PreferenceStore;
use GPForum::Service::Identity::RegistrationStore;
use GPForum::Service::Identity::SessionStore;
use GPForum::Service::Identity::Support;
use GPForum::Service::Identity::TokenStore;
use GPForum::Service::Password;
use GPForum::Service::SessionToken;

our $VERSION = '0.001';

const my $DAY_SECONDS  => 86_400;
const my $SESSION_DAYS => 30;

has schema     => undef;
has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Service::Id;
    return GPForum::Service::Id->new;
};
has password => sub { return GPForum::Service::Password->new; };
has recorder => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
has session_tokens  => sub { return GPForum::Service::SessionToken->new; };
has session_seconds => sub { return $SESSION_DAYS * $DAY_SECONDS; };
has support         => sub { return GPForum::Service::Identity::Support->new; };
has audit           => sub {
    my ($self) = @_;

    return GPForum::Service::Identity::Audit->new(
        id_service => $self->id_service,
        recorder   => $self->recorder,
        schema     => $self->schema,
    );
};
has credential_store => sub {
    my ($self) = @_;

    return GPForum::Service::Identity::CredentialStore->new(
        clock      => $self->clock,
        id_service => $self->id_service,
        schema     => $self->schema,
        support    => $self->support,
    );
};
has session_store => sub {
    my ($self) = @_;

    return GPForum::Service::Identity::SessionStore->new(
        clock           => $self->clock,
        id_service      => $self->id_service,
        schema          => $self->schema,
        session_seconds => $self->session_seconds,
        session_tokens  => $self->session_tokens,
        support         => $self->support,
    );
};
has token_store => sub {
    my ($self) = @_;

    return GPForum::Service::Identity::TokenStore->new(
        clock          => $self->clock,
        id_service     => $self->id_service,
        schema         => $self->schema,
        session_tokens => $self->session_tokens,
        support        => $self->support,
    );
};
has preference_store => sub {
    my ($self) = @_;

    return GPForum::Service::Identity::PreferenceStore->new(
        clock   => $self->clock,
        schema  => $self->schema,
        support => $self->support,
    );
};
has account_store => sub {
    my ($self) = @_;

    return GPForum::Service::Identity::AccountStore->new(
        audit            => $self->audit,
        clock            => $self->clock,
        credential_store => $self->credential_store,
        password         => $self->password,
        schema           => $self->schema,
        session_store    => $self->session_store,
        support          => $self->support,
        token_store      => $self->token_store,
    );
};
has auth_store => sub {
    my ($self) = @_;

    return GPForum::Service::Identity::AuthStore->new(
        credential_store => $self->credential_store,
        password         => $self->password,
        schema           => $self->schema,
        session_store    => $self->session_store,
        support          => $self->support,
    );
};
has registration_store => sub {
    my ($self) = @_;

    return GPForum::Service::Identity::RegistrationStore->new(
        audit            => $self->audit,
        credential_store => $self->credential_store,
        id_service       => $self->id_service,
        schema           => $self->schema,
    );
};

sub create_registration {
    my ( $self, $registration ) = @_;

    return $self->registration_store->create_registration($registration);
}

sub authenticate_login {
    my ( $self, $input ) = @_;

    return $self->auth_store->authenticate_login($input);
}

sub request_password_reset {
    my ( $self, $input ) = @_;

    return $self->account_store->request_password_reset($input);
}

sub reset_password {
    my ( $self, $input ) = @_;

    return $self->account_store->reset_password($input);
}

sub change_password {
    my ( $self, $input ) = @_;

    return $self->account_store->change_password($input);
}

sub request_email_change {
    my ( $self, $input ) = @_;

    return $self->account_store->request_email_change($input);
}

sub confirm_email_change {
    my ( $self, $input ) = @_;

    return $self->account_store->confirm_email_change($input);
}

sub request_email_verification {
    my ( $self, $input ) = @_;

    return $self->account_store->request_email_verification($input);
}

sub confirm_email_verification {
    my ( $self, $input ) = @_;

    return $self->account_store->confirm_email_verification($input);
}

sub revoke_session {
    my ( $self, $input ) = @_;

    return $self->session_store->revoke_session($input);
}

sub validate_session {
    my ( $self, $input ) = @_;

    return $self->session_store->validate_session($input);
}

sub preferred_locale_for_user {
    my ( $self, $input ) = @_;

    return $self->preference_store->preferred_locale_for_user($input);
}

sub update_preferred_locale {
    my ( $self, $input ) = @_;

    return $self->preference_store->update_preferred_locale($input);
}

sub preferred_theme_for_user {
    my ( $self, $input ) = @_;

    return $self->preference_store->preferred_theme_for_user($input);
}

sub update_preferred_theme {
    my ( $self, $input ) = @_;

    return $self->preference_store->update_preferred_theme($input);
}

1;

__END__

=head1 NAME

GPForum::Service::Identity::Store - Identity write workflow.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $store = GPForum::Service::Identity::Store->new(schema => $schema);

=head1 DESCRIPTION

Coordinates identity writes by delegating to dedicated stores. Registration,
login, password, email, session, and preference persistence live outside this
facade.

=head1 SUBROUTINES/METHODS

=head2 create_registration

Delegates prepared registration persistence to the registration store.

=head2 authenticate_login

Delegates credential verification and session creation to the auth store.

=head2 request_password_reset

Delegates password-reset issuance to the account store.

=head2 reset_password

Delegates reset completion to the account store.

=head2 change_password

Delegates authenticated password rotation to the account store.

=head2 request_email_change

Delegates email-change issuance to the account store.

=head2 confirm_email_change

Delegates email-change confirmation to the account store.

=head2 request_email_verification

Delegates registration verification issuance to the account store.

=head2 confirm_email_verification

Delegates registration verification completion to the account store.

=head2 revoke_session

Revokes one server session.

=head2 validate_session

Validates and refreshes a live server session.

=head2 preferred_locale_for_user

Delegates locale reads to the preference store.

=head2 update_preferred_locale

Delegates locale writes to the preference store.

=head2 preferred_theme_for_user

Delegates theme reads to the preference store.

=head2 update_preferred_theme

Delegates theme writes to the preference store.

=head1 DIAGNOSTICS

Duplicate usernames/emails return field errors. Invalid credentials return
C<invalid_credentials>.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a DBIx::Class schema with User, Credential, Session, and
IdentityToken resultsets.

=head1 DEPENDENCIES

Uses the identity registration, account, auth, credential, session, token,
preference, and audit stores.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Preference updates are not transactional with notification settings.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
