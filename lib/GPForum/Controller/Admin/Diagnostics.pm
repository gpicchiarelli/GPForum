# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Admin::Diagnostics;

use Mojo::Base 'GPForum::Controller::Admin::Base', -signatures;
use v5.40;

our $VERSION = '0.001';

# Neither is behind a danger confirmation: a test message goes only to the
# administrator who asked for it, and the check scans three files of its own.
# Nothing is taken away. Neither reads a recipient or a file from the
# request: there is none to read.
sub mail_test ($self) {
    my $actor_user_id = $self->authorized_write_user_id;
    if ( !$actor_user_id ) {
        return;
    }

    my $result = $self->gp_admin_workflow->send_test_mail(
        {
            actor_user_id => $actor_user_id,
            command_id    => $self->command_id_param,
        }
    );
    my $failure = $self->write_failure($result);
    return $failure if $failure;

    my $stored = $result->{stored} || {};
    return $self->diagnostics_response(
        $self->admin_access->mail_test_status( $stored->{outcome} ), $stored );
}

sub antivirus_check ($self) {
    my $actor_user_id = $self->authorized_write_user_id;
    if ( !$actor_user_id ) {
        return;
    }

    my $result = $self->gp_admin_workflow->check_antivirus(
        {
            actor_user_id => $actor_user_id,
            command_id    => $self->command_id_param,
        }
    );
    my $failure = $self->write_failure($result);
    return $failure if $failure;

    my $stored = $result->{stored} || {};
    return $self->diagnostics_response(
        $self->admin_access->antivirus_check_status( $stored->{status} ),
        $stored );
}

1;

__END__

=head1 NAME

GPForum::Controller::Admin::Diagnostics - Send a test message and check the antivirus from the console.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    POST /admin/mail/test
    POST /admin/antivirus/check

=head1 DESCRIPTION

The console side of C<bin/gpforum-mail-check --send> and
C<bin/gpforum-antivirus-check> (quality program 6.5). The work, and the audit
of it, is L<GPForum::Service::Admin::Diagnostics>'s; both run under a command
id, behind the admin write permission, CSRF check and rate limit.

=head1 SUBROUTINES/METHODS

=head2 mail_test

Sends one test message to the signed-in administrator's own address;
redirects to the settings page, or answers JSON with the outcome.

=head2 antivirus_check

Runs the antivirus check; redirects to the settings page, or answers JSON
with the report.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Controller::Admin::Base>.

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
