package GPForum::Service::Portability::ImportManifestValidator;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

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

sub validate {
    my ( $self, $manifest ) = @_;

    my %errors;
    _require_fields( \%errors, $manifest );
    _require_record_counts( \%errors, $manifest->{records} || {} );

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

sub _require_record_counts {
    my ( $errors, $records ) = @_;

    for my $field (@REQUIRED_RECORD_COUNTS) {
        if ( !exists $records->{$field} || $records->{$field} < 0 ) {
            $errors->{"records.$field"} = "records.$field must be non-negative";
        }
    }

    return;
}

1;
