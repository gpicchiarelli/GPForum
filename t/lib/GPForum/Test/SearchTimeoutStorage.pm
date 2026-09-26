# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SearchTimeoutStorage;

use strict;
use warnings;

use Mojo::Base 'GPForum::Test::Storage';

use GPForum::Test::SearchTimeoutDbh;

our $VERSION = '0.001';

# Every statement run through dbh_do, as [ $sql, @bind, $transaction_depth ].
has statements => sub { return []; };

# DBIx::Class's dbh_do: the code is called with the storage and a connected
# handle, which here records what it is asked to run.
sub dbh_do {
    my ( $self, $code ) = @_;

    return $code->( $self,
        GPForum::Test::SearchTimeoutDbh->new( storage => $self ) );
}

1;
