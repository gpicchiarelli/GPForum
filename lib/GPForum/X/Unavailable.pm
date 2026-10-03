# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::X::Unavailable;

use Mojo::Base 'GPForum::X', -signatures;
use v5.40;

our $VERSION = '0.001';

has failure_type => 'transport';

1;

__END__

=head1 NAME

GPForum::X::Unavailable - A dependency did not answer.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    GPForum::X::Unavailable->throw( message => 'clamd did not answer' );

=head1 DESCRIPTION

A dependency did not answer: clamd, the shared cache, Minion, the mail
server, pg_dump or pg_restore, the notification fan-out. Its failure type is
C<transport>, so the outbox retries it. ADR 0118 maps it to a 503 answer
and exit status 1 as the callers come to catch it.

It is a L<GPForum::X>: it stringifies to its message and is always true.

=head1 SUBROUTINES/METHODS

None beyond L<GPForum::X>'s. C<failure_type> is C<transport>.

=head1 DIAGNOSTICS

None of its own.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::X>.

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
