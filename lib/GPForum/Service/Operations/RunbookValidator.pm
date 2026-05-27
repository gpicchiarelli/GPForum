package GPForum::Service::Operations::RunbookValidator;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my @REQUIRED_BACKUP_FIELDS => qw(
  postgres_method
  object_storage_policy
  configuration_policy
  retention_days
  restore_test_cadence
);
const my @REQUIRED_ROLLBACK_FIELDS => qw(
  trigger
  owner
  health_check
  forward_fix
);

sub validate_backup {
    my ( $self, $runbook ) = @_;

    return _validate_required( $runbook, \@REQUIRED_BACKUP_FIELDS );
}

sub validate_rollback {
    my ( $self, $runbook ) = @_;

    return _validate_required( $runbook, \@REQUIRED_ROLLBACK_FIELDS );
}

sub _validate_required {
    my ( $runbook, $required_fields ) = @_;

    my %missing;
    for my $field ( @{$required_fields} ) {
        if ( !defined $runbook->{$field} || !length $runbook->{$field} ) {
            $missing{$field} = "$field is required";
        }
    }

    return {
        ok      => keys %missing ? 0 : 1,
        missing => \%missing,
    };
}

1;

