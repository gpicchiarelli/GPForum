package GPForum::ViewModel::Identity::Presenter;

use strict;
use warnings;

use Mojo::Base 'GPForum::ViewModel::Base';

our $VERSION = '0.001';

sub register_form {
    my ( $self, %input ) = @_;

    my $errors = $input{errors} || {};
    my $values = $input{values} || {};
    my $fields = $self->_form_fields(
        errors => $errors,
        values => $values,
        specs  => [
            {
                autocomplete => 'username',
                id           => 'register-username',
                label_key    => 'auth.username',
                name         => 'username',
                type         => 'text',
                value_key    => 'username',
            },
            {
                autocomplete => 'name',
                id           => 'register-display-name',
                label_key    => 'auth.display_name',
                name         => 'display_name',
                type         => 'text',
                value_key    => 'display_name',
            },
            {
                autocomplete => 'email',
                id           => 'register-email',
                label_key    => 'auth.email',
                name         => 'email',
                type         => 'email',
                value_key    => 'email_normalized',
            },
            {
                autocomplete => 'new-password',
                id           => 'register-password',
                label_key    => 'auth.password',
                name         => 'password',
                type         => 'password',
            },
        ],
    );

    return {
        errors       => $errors,
        error_fields =>
          [ map { { id => $_->{id}, name => $_->{name} } } @{$fields} ],
        fields => $fields,
        ui     => {
            described_by => $self->_form_described_by(
                $errors,                  'registration',
                'register-error-summary', 'register-form-error'
            ),
            heading_id => 'register-heading',
        },
        values => $values,
    };
}

sub login_form {
    my ( $self, %input ) = @_;

    my $errors = $input{errors} || {};
    my $values = $input{values} || {};
    my $fields = $self->_form_fields(
        errors => $errors,
        values => $values,
        specs  => [
            {
                autocomplete => 'username',
                id           => 'login-identifier',
                label_key    => 'auth.username_or_email',
                name         => 'identifier',
                type         => 'text',
                value_key    => 'identifier',
            },
            {
                autocomplete => 'current-password',
                id           => 'login-password',
                label_key    => 'auth.password',
                name         => 'password',
                type         => 'password',
            },
        ],
    );

    return {
        errors       => $errors,
        error_fields =>
          [ map { { id => $_->{id}, name => $_->{name} } } @{$fields} ],
        fields => $fields,
        ui     => {
            described_by => $self->_form_described_by(
                $errors, 'login', 'login-error-summary', 'login-form-error'
            ),
            heading_id => 'login-heading',
        },
        values => $values,
    };
}

sub profile {
    my ( $self, $profile ) = @_;

    $profile ||= {};
    my $user         = $profile->{user} || {};
    my $safe_profile = {
        %{$profile},
        counts  => $profile->{counts}  || {},
        replies => $profile->{replies} || { items => [] },
        threads => $profile->{threads} || { items => [] },
        trust   => $profile->{trust}   || {},
        user    => {
            %{$user},
            profile_label => $user->{profile_label}
              || $self->profile_label( $user->{username} ),
        },
    };
    $safe_profile->{ui} = {
        activity_label => 'profile.profile_activity_pagination',
        heading_id     => 'profile-heading',
    };

    return $safe_profile;
}

sub _form_fields {
    my ( $self, %input ) = @_;

    my $errors = $input{errors} || {};
    my $values = $input{values} || {};

    return [
        map {
            my $error_id  = $_->{id} . '-error';
            my $has_error = exists $errors->{ $_->{name} };
            +{
                %{$_},
                error       => $errors->{ $_->{name} },
                error_attrs => $self->field_error_attrs(
                    described_by => $error_id,
                    has_error    => $has_error,
                ),
                error_id => $error_id,
                value    => $values->{ $_->{value_key} || $_->{name} }
                  // $values->{ $_->{name} } // q{},
            }
        } @{ $input{specs} || [] }
    ];
}

sub _form_described_by {
    my ( $self, $errors, $general_key, $summary_id, $general_error_id ) = @_;

    for my $name ( keys %{$errors} ) {
        return $summary_id if $name ne $general_key;
    }

    return $errors->{$general_key} ? $general_error_id : q{};
}

1;
