package GPForum::Test::RateLimitSchema;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::RateLimitDbh;
use GPForum::Test::RateLimitStorage;

our $VERSION = '0.001';

has dbh => sub { return GPForum::Test::RateLimitDbh->new; };

sub storage {
    my ($self) = @_;

    return GPForum::Test::RateLimitStorage->new( dbh => $self->dbh );
}

1;
