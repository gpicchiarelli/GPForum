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

__END__

=head1 NAME

GPForum::Service::Operations::RunbookValidator - Checks that a backup or rollback runbook names every required field.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $validator = GPForum::Service::Operations::RunbookValidator->new;
    my $result    = $validator->validate_backup(
        {
            postgres_method       => 'pg_basebackup',
            object_storage_policy => 'versioned bucket backup',
            configuration_policy  => 'encrypted repository snapshot',
            retention_days        => 30,
            restore_test_cadence  => 'monthly',
        }
    );
    warn join q{, }, values %{ $result->{missing} } if !$result->{ok};

=head1 DESCRIPTION

A runbook is a plain hash of fields. This module says whether a backup
runbook or a rollback runbook fills in the fields an operator needs before
relying on it, and which ones are missing. It checks presence only: a field
that is undefined or an empty string is missing; any other value passes.

A backup runbook needs C<postgres_method>, C<object_storage_policy>,
C<configuration_policy>, C<retention_days> and C<restore_test_cadence>. A
rollback runbook needs C<trigger>, C<owner>, C<health_check> and
C<forward_fix>.

=head1 SUBROUTINES/METHODS

=head2 validate_backup

Takes a backup runbook hashref. Returns C<< { ok => 1|0, missing => \%missing } >>,
where C<%missing> maps each absent or empty required field to the message
"FIELD is required". C<ok> is 1 when nothing is missing.

=head2 validate_rollback

The same check for a rollback runbook hashref, against the rollback fields.
Returns the same C<< { ok, missing } >> hashref.

=head1 DIAGNOSTICS

Croaks nothing itself: an incomplete runbook is reported in C<missing>
with C<ok> set to 0, and an undefined runbook reports every field missing.
A value that is not a hash reference dies under strict refs when it is
read.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>.

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
