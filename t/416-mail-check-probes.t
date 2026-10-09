# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use Email::Sender::Transport::Test;
use GPForum::Config;
use GPForum::Service::Identity::Mailer;
use GPForum::Service::Operations::MailCheck;

our $VERSION = '0.001';

# Where mail-check looks for sendmail before PATH.
my @SENDMAIL_LOCATIONS =
  qw(/usr/sbin/sendmail /usr/lib/sendmail /usr/bin/sendmail);

# A configuration that cannot send fails before any probe, and the evidence
# says the probe it stopped at was the configuration.
my $pigeon = GPForum::Service::Operations::MailCheck->new(
    config => GPForum::Config->new(
        mail_transport  => 'pigeon',
        mail_from       => 'noreply@forum.test',
        public_base_url => 'http://forum.test',
    ),
)->run( { mode => 'dry_run' } );
is_deeply(
    [ @{$pigeon}{qw(status error)}, $pigeon->{config}{mail_transport} ],
    [ 'fail', 'mail_transport must be sendmail, smtp, log, or test', 'pigeon' ],
    'an unknown transport fails, saying which values are allowed'
);
is_deeply(
    $pigeon->{probe},
    { status => 'fail', action => 'config' },
    'at the configuration step'
);

# The test transport's probe counts what the transport holds.
my $config = GPForum::Config->new(
    mail_transport  => 'test',
    mail_from       => 'noreply@forum.test',
    public_base_url => 'http://forum.test',
);
my $transport = Email::Sender::Transport::Test->new;
my $check     = GPForum::Service::Operations::MailCheck->new(
    config => $config,
    mailer => GPForum::Service::Identity::Mailer->new(
        config          => $config,
        from_address    => 'noreply@forum.test',
        public_base_url => 'http://forum.test',
        transport       => $transport,
    ),
);
is( $check->run( { mode => 'dry_run' } )->{probe}{delivery_count},
    1, 'the first probe leaves one delivery' );
is( $check->run( { mode => 'dry_run' } )->{probe}{delivery_count},
    2, 'the next one two' );
is( $transport->delivery_count, 2, 'as the transport counts them' );

# With no resolver given, sendmail is looked for in the usual places first,
# then on PATH.
my $bin  = path( tempdir( CLEANUP => 1 ) );
my $fake = $bin->child('sendmail');
$fake->spew("#!/bin/sh\nexit 0\n");
$fake->chmod( oct '0755' );
my ($installed) = grep { -x } @SENDMAIL_LOCATIONS;
{
    local $ENV{PATH} = join q{:}, q{}, $bin->to_string;
    my $found = GPForum::Service::Operations::MailCheck->new(
        config => GPForum::Config->new(
            mail_transport  => 'sendmail',
            mail_from       => 'noreply@forum.test',
            public_base_url => 'http://forum.test',
        ),
    )->run( { mode => 'dry_run' } )->{probe};
    is(
        $found->{path},
        $installed // $fake->to_string,
        'sendmail is found where it is installed, else on PATH'
    );
    is( $found->{status}, 'pass', 'and the probe passes' );
}

done_testing();

1;
