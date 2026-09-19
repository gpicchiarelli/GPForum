package GPForum::Test::DbQueryStatsSchema;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::DbQueryStatsStorage;

our $VERSION = '0.001';

has storage => sub { return GPForum::Test::DbQueryStatsStorage->new; };

1;
