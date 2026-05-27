package GPForum::Service::Plugin::ManifestValidator;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my @REQUIRED_FIELDS => qw(
  name
  version
  author
  compatible_gpforum_range
  capabilities
  required_permissions
  hooks
);

sub validate {
    my ( $self, $manifest ) = @_;

    my %errors;
    _require_fields( \%errors, $manifest );
    _require_array( \%errors, $manifest, 'capabilities' );
    _require_array( \%errors, $manifest, 'required_permissions' );
    _validate_hooks( \%errors, $manifest->{hooks} || [] );

    return {
        ok     => keys %errors ? 0 : 1,
        errors => \%errors,
    };
}

sub _require_fields {
    my ( $errors, $manifest ) = @_;

    for my $field (@REQUIRED_FIELDS) {
        if ( !exists $manifest->{$field} || !defined $manifest->{$field} ) {
            $errors->{$field} = "$field is required";
        }
    }

    return;
}

sub _require_array {
    my ( $errors, $manifest, $field ) = @_;

    if ( exists $manifest->{$field} && ref $manifest->{$field} ne 'ARRAY' ) {
        $errors->{$field} = "$field must be an array";
    }

    return;
}

sub _validate_hooks {
    my ( $errors, $hooks ) = @_;

    if ( ref $hooks ne 'ARRAY' ) {
        $errors->{hooks} = 'hooks must be an array';
        return;
    }

    my $position = 0;
    for my $hook ( @{$hooks} ) {
        _validate_hook( $errors, $hook, $position );
        $position++;
    }

    return;
}

sub _validate_hook {
    my ( $errors, $hook, $position ) = @_;

    for my $field (qw(hook_name callback_name)) {
        if ( !exists $hook->{$field} || !defined $hook->{$field} ) {
            $errors->{"hooks.$position.$field"} =
              "hooks.$position.$field is required";
        }
    }

    return;
}

1;
