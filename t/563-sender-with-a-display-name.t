# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';

use GPForum::Config;
use GPForum::X::Config;

our $VERSION = '0.001';

# Walkthrough 2, friction 12 (the settings review): a GPFORUM_MAIL_FROM with
# a display name, "Forum <forum@forum.example.com>", slipped past the check
# that refuses the template's example sender in staging and production. Its
# domain was read as "forum.example.com>", which no example name ends in.

const my %DEPLOYED => (
    GPFORUM_ENV             => 'production',
    GPFORUM_SESSION_SECRET  => 'a' x 64,
    GPFORUM_METRICS_TOKEN   => 'b' x 32,
    GPFORUM_PUBLIC_BASE_URL => 'https://forum.gpforum.test',
);

for my $sender (
    'Forum <forum@forum.example.com>',
    'GPForum Walk <noreply@example.org>',
    '"Forum, the" < forum@forum.invalid >',
  )
{
    is_deeply(
        [ _keys($sender) ],
        [ [ GPFORUM_MAIL_FROM => 'config.placeholder_mail_from' ] ],
        "production refuses $sender"
    );
}

is_deeply(
    [ _keys('Forum <forum@localhost>') ],
    [ [ GPFORUM_MAIL_FROM => 'config.mail_from_local' ] ],
    'and a display name before a local address'
);

for
  my $sender ( 'Forum <forum@forum.gpforum.test>', 'forum@forum.gpforum.test' )
{
    is_deeply( [ _keys($sender) ], [], "while $sender is taken" );
}

done_testing();

sub _keys ($sender) {
    my $problems = [];
    try {
        GPForum::Config->from_environment(
            { %DEPLOYED, GPFORUM_MAIL_FROM => $sender } );
    }
    catch ($error) {
        my $invalid = GPForum::X::Config->caught($error) or die $error;    ## no critic (ErrorHandling::RequireCarping) -- rethrows the caught error as it was raised
        $problems = $invalid->problems;
    };

    return map { [ $_->{variable}, $_->{key} ] } @{$problems};
}

1;
