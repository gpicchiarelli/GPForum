# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::FailingAdminAuditReview;

use Carp qw(croak);
use Mojo::Base 'GPForum::Test::AdminWebServices';
use v5.40;

our $VERSION = '0.001';

# The audit review's real filter check, then a page read that fails, as the
# database going away between the two would.
sub page {
    croak 'audit page read failed';
}

1;

__END__

=head1 NAME

GPForum::Test::FailingAdminAuditReview - An audit review whose page read
fails.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $app->helper(
        gp_admin_audit_review => sub {
            return GPForum::Test::FailingAdminAuditReview->new;
        }
    );

=head1 DESCRIPTION

A L<GPForum::Test::AdminWebServices> whose C<filters> still checks the audit
filters as the console does, and whose C<page> croaks.

=head1 SUBROUTINES/METHODS

=head2 page

Croaks C<audit page read failed>.

=head1 DIAGNOSTICS

C<page> always croaks.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Carp>, L<GPForum::Test::AdminWebServices>, L<Mojo::Base>.

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
