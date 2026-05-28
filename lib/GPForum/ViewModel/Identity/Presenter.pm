package GPForum::ViewModel::Identity::Presenter;

use strict;
use warnings;

use Mojo::Base 'GPForum::ViewModel::Base';

our $VERSION = '0.001';

sub register_form {
    my ( $self, %input ) = @_;

    my $errors = $input{errors} || {};
    my $values = $input{values} || {};
    my $fields = $self->form_fields(
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
        error_fields => $self->form_error_fields($fields),
        fields       => $fields,
        ui           => {
            described_by => $self->form_described_by(
                errors           => $errors,
                general_error_id => 'register-form-error',
                general_key      => 'registration',
                summary_id       => 'register-error-summary',
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
    my $fields = $self->form_fields(
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
        error_fields => $self->form_error_fields($fields),
        fields       => $fields,
        ui           => {
            described_by => $self->form_described_by(
                errors           => $errors,
                general_error_id => 'login-form-error',
                general_key      => 'login',
                summary_id       => 'login-error-summary',
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

sub settings_page {
    my ( $self, %input ) = @_;

    return {
        digest_frequency_options => $input{digest_frequency_options} || [],
        locale_options           => $input{locale_options}           || [],
        notification_preferences => $input{notification_preferences} || [],
        theme_options            => $input{theme_options}            || [],
        ui                       => {
            appearance_heading_id    => 'settings-appearance-heading',
            heading_id               => 'settings-heading',
            notifications_heading_id => 'settings-notifications-heading',
        },
    };
}

1;
