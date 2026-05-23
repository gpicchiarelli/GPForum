package GPForum::Test::MigrationSchema;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::MigrationStorage;

our $VERSION = '0.001';

has storage => sub { return GPForum::Test::MigrationStorage->new; };

1;
