package GPForum::Test::FailingRateLimitStore;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

our $VERSION = '0.001';

sub check {
    croak 'rate limit primary store unavailable';
}

sub snapshot {
    croak 'rate limit primary store unavailable';
}

1;
