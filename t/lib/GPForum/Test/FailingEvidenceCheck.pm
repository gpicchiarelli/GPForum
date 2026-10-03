# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::FailingEvidenceCheck;

use Carp qw(croak);
use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# What an evidence command's check raises when it stops instead of reporting:
# DBI's connect error, which repeats the DSN and the password= in it, with
# the location DBI appends; croak adds the command's. Before it a file
# lookup fails, as one does somewhere in most real failures: it leaves $! at
# ENOENT, 2, and an uncaught exception exits with $! -- the misuse code.
has error => sub {
    return
        q{DBI connect('dbname=gpforum;host=127.0.0.1;password=hunter2',}
      . q{'gpforum',...) failed: Connection refused}
      . ' at /usr/lib/perl5/DBI.pm line 1639.';
};
has missing => '/nonexistent/gpforum-evidence-check';

sub run {
    my ($self) = @_;

    if ( -e $self->missing ) {
        croak 'the file this check looks up in vain exists';
    }
    croak $self->error;
}

sub format_evidence {
    croak 'a check that failed has no evidence to format';
}

sub exit_status {
    croak 'a check that failed has no exit status of its own';
}

1;
