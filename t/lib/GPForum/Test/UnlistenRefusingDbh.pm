# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::UnlistenRefusingDbh;

use Mojo::Base 'GPForum::Test::RealtimeBusDbh';
use v5.40;

our $VERSION = '0.001';

my $PARENT_DO = GPForum::Test::RealtimeBusDbh->can('do');

# Once set, an UNLISTEN dies as it does on a connection the server dropped
# between the check and the statement.
has refuse_unlisten => 0;

sub _refusing_do {
    my ( $self, @arguments ) = @_;

    if ( $self->refuse_unlisten && $arguments[0] =~ /\A UNLISTEN \s/msx ) {
        die "server closed the connection unexpectedly\n";
    }

    return $self->$PARENT_DO(@arguments);
}

*GPForum::Test::UnlistenRefusingDbh::do = \&_refusing_do;

1;
