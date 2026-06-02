package GPForum::Test::PostStoreLockSchema;

use strict;
use warnings;

use Mojo::Base 'GPForum::Test::Schema';

use GPForum::Test::PostStoreLockStorage;

our $VERSION = '0.001';

has lock_dbh => undef;

sub storage {
    my ($self) = @_;

    return GPForum::Test::PostStoreLockStorage->new( dbh => $self->lock_dbh );
}

1;
