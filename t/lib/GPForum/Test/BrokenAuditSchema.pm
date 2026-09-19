package GPForum::Test::BrokenAuditSchema;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

our $VERSION = '0.001';

sub resultset {
    croak 'audit lookup failed';
}

1;
