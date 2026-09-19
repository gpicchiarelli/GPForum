package GPForum::Test::SuspendedParticipation;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub can_participate {
    return { ok => 0, reason => 'suspended' };
}

1;
