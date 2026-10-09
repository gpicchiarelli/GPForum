# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RefusedSchema;

use Carp qw(croak);
use Mojo::Base -base;
use v5.40;

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

    return undef if !length $self->error;

    croak $self->error;
}

# A transaction needs the connection first, and fails as it does.
sub txn_do {
    my ($self) = @_;

    return $self->dbh;
}

1;
