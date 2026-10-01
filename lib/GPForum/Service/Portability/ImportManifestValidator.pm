# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Portability::ImportManifestValidator;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my @REQUIRED_FIELDS => qw(
  source_system
  source_version
  adapter_name
  records
  dry_run
);

const my @REQUIRED_RECORD_COUNTS => qw(
  users
  categories
  threads
  posts
);

sub validate ( $self, $manifest ) {
    my %errors;
    _require_fields( \%errors, $manifest );
    _require_record_counts( \%errors, $manifest->{records} || {} );

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

sub _require_record_counts ( $errors, $records ) {
    for my $field (@REQUIRED_RECORD_COUNTS) {
        if ( !exists $records->{$field} || $records->{$field} < 0 ) {
            $errors->{"records.$field"} = "records.$field must be non-negative";
        }
    }

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Portability::ImportManifestValidator - Check that an import manifest names its source and counts its records.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $validator = GPForum::Service::Portability::ImportManifestValidator->new;
    my $result    = $validator->validate(
        {
            adapter_name   => 'legacy_forum_v1',
            dry_run        => 1,
            records        => {
                categories => 1,
                posts      => 4,
                threads    => 1,
                users      => 2,
            },
            source_system  => 'legacy-forum',
            source_version => '1.4',
        }
    );
    # { ok => 1, errors => {} }

=head1 DESCRIPTION

The shape check an import manifest passes before
L<GPForum::Service::Portability::ImportJobStore> accepts the job. It checks
presence only: C<source_system>, C<source_version>, C<adapter_name>,
C<records> and C<dry_run> must be present and defined, and C<records> must
carry C<users>, C<categories>, C<threads> and C<posts> counts that are not
negative. It does not compare the counts with the data.

=head1 SUBROUTINES/METHODS

=head2 validate

Takes the manifest hash reference. Returns C<< { ok, errors } >>, C<ok>
being 1 when there are no errors.

=head1 DIAGNOSTICS

Nothing is thrown. The errors are C<FIELD is required>, keyed by the field,
and C<records.NAME must be non-negative>, keyed C<records.NAME>, for a
count that is negative or missing.

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
