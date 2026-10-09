# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::FailingIdentitySecurityAudit;

use Carp qw(croak);
use Mojo::Base 'GPForum::Test::IdentitySecurityAudit', -signatures;
use v5.40;

our $VERSION = '0.001';

# The sign-in itself goes through; recording it fails, as the audit table
# being unreachable would.
sub record_login_request ( $self, $input ) {
    croak 'security audit is down';
}

1;

__END__

=head1 NAME

GPForum::Test::FailingIdentitySecurityAudit - An identity security audit
whose login record fails.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $app->helper(
        gp_identity_security_audit => sub {
            return GPForum::Test::FailingIdentitySecurityAudit->new;
        }
    );

=head1 DESCRIPTION

A L<GPForum::Test::IdentitySecurityAudit> whose C<record_login_request>
croaks, so a test can check that a sign-in survives its audit failing.

=head1 SUBROUTINES/METHODS

=head2 record_login_request

Croaks C<security audit is down>.

=head1 DIAGNOSTICS

C<record_login_request> always croaks.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Carp>, L<GPForum::Test::IdentitySecurityAudit>, L<Mojo::Base>.

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
