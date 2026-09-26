# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::RunbookValidator;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

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

sub validate_backup ( $self, $runbook ) {
    return _validate_required( $runbook, \@REQUIRED_BACKUP_FIELDS );
}

sub validate_rollback ( $self, $runbook ) {
    return _validate_required( $runbook, \@REQUIRED_ROLLBACK_FIELDS );
}

sub _validate_required ( $runbook, $required_fields ) {
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

