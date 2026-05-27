package GPForum::ViewModel::Identity::Presenter;

use strict;
use warnings;

use Mojo::Base 'GPForum::ViewModel::Base';

our $VERSION = '0.001';

sub register_form {
    my ( $self, %input ) = @_;

    my $errors = $input{errors} || {};

    return {
        errors => $errors,
        ui     => {
            described_by => keys %{$errors} ? 'register-error-summary' : q{},
            heading_id   => 'register-heading',
        },
        values => $input{values} || {},
    };
}

sub login_form {
    my ( $self, %input ) = @_;

    my $errors = $input{errors} || {};

    return {
        errors => $errors,
        ui     => {
            described_by => keys %{$errors} ? 'login-error-summary' : q{},
            heading_id   => 'login-heading',
        },
        values => $input{values} || {},
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

1;
