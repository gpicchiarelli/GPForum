# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Plugin::ManifestValidator;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

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

sub validate ( $self, $manifest ) {
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

sub _require_fields ( $errors, $manifest ) {
    for my $field (@REQUIRED_FIELDS) {
        if ( !exists $manifest->{$field} || !defined $manifest->{$field} ) {
            $errors->{$field} = "$field is required";
        }
    }

    return;
}

sub _require_array ( $errors, $manifest, $field ) {
    if ( exists $manifest->{$field} && ref $manifest->{$field} ne 'ARRAY' ) {
        $errors->{$field} = "$field must be an array";
    }

    return;
}

sub _validate_hooks ( $errors, $hooks ) {
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

sub _validate_hook ( $errors, $hook, $position ) {
    for my $field (qw(hook_name callback_name)) {
        if ( !exists $hook->{$field} || !defined $hook->{$field} ) {
            $errors->{"hooks.$position.$field"} =
              "hooks.$position.$field is required";
        }
    }

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Plugin::ManifestValidator - Check that a plugin manifest has the fields GPForum needs.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $result = GPForum::Service::Plugin::ManifestValidator->new->validate(
        {
            name                     => 'example',
            version                  => '1.0.0',
            author                   => 'Someone',
            compatible_gpforum_range => '>=0.001',
            capabilities             => [],
            required_permissions     => [],
            hooks => [ { hook_name => 'post.created', callback_name => 'on_post' } ],
        }
    );
    # $result->{ok}, $result->{errors}

=head1 DESCRIPTION

A structural check of a plugin manifest, reporting every problem at once.
The manifest needs C<name>, C<version>, C<author>,
C<compatible_gpforum_range>, C<capabilities>, C<required_permissions> and
C<hooks>; C<capabilities>, C<required_permissions> and C<hooks> must be
arrays, and every hook needs a C<hook_name> and a C<callback_name>. The
values themselves are not interpreted here.

=head1 SUBROUTINES/METHODS

=head2 validate

Takes the manifest as a hash reference. Returns C<< { ok => 1, errors => {} } >>
when it passes, or C<< ok => 0 >> with C<errors> keyed by field: C<FIELD is
required> for a missing or undefined field, C<FIELD must be an array> for a
non-array C<capabilities>, C<required_permissions> or C<hooks>, and
C<hooks.N.FIELD is required> for a hook at position N missing C<hook_name> or
C<callback_name>.

=head1 DIAGNOSTICS

Problems are returned in C<errors>, not thrown. The manifest must be a hash
reference, and a hook given as a string or as a reference other than a hash
dies on the dereference.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

None beyond L<Mojo::Base> and L<Const::Fast>.

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
