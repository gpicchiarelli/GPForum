# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RefusedSchema;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

our $VERSION = '0.001';

# A schema whose database refuses the connection, as DBIx::Class reports it:
# its own prefix, DBI's message repeating the DSN -- password= included --
# over two lines, DBI's location, and then the caller's, which croak adds.
# With no error, the storage answers with no handle and no reason.
has error => sub {
    return
        'DBIx::Class::Storage::DBI::catch {...} (): DBI Connection failed:'
      . q{ DBI connect('dbname=gpforum;host=127.0.0.1;port=1;}
      . q{password=hunter2','gpforum',...) failed: connection to server at}
      . qq{ "127.0.0.1", port 1 failed: Connection refused\n}
      . "\tIs the server running on that host and accepting TCP/IP"
      . ' connections? at /usr/lib/perl5/DBIx/Class/Storage/DBI.pm line 1639.';
};

sub storage {
    my ($self) = @_;

    return $self;
}

sub dbh {
    my ($self) = @_;

    my $undefined;
    return $undefined if !length $self->error;

    croak $self->error;
}

1;
